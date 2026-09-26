#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# zsh/zshenv's GIT_CEILING_DIRECTORIES guard: stops git's upward directory walk
# from crossing out of a docker-sbx sandbox into the host's envs repo, but only
# when that envs directory actually exists (see the comment above the block in
# zsh/zshenv for why the gate is a directory stat, not a `canga`-on-PATH check).
# Hermetic: `env -i` with a scratch HOME and an EMPTY PATH directory, mirroring
# tests/zshenv_contract_test.sh, so nothing on the tester's machine (a real
# CANGA_HOST_BASE_DIR, GIT_CEILING_DIRECTORIES or envs checkout) can leak in.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ck() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail "$1: got [$2] want [$3]"; fi; }

if ! command -v zsh >/dev/null 2>&1; then
  if [ -n "${STRICT:-}" ]; then fail "zsh not installed and STRICT=1"; fi
  echo "SKIP: git_ceiling_test (zsh not installed; enforced in CI)"
  exit 0
fi
zsh_bin="$(command -v zsh)"

work="$(mktemp -d "${TMPDIR:-/tmp}/git_ceiling_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
empty="$work/emptybin"; mkdir -p "$empty"
h="$work/home"; mkdir -p "$h"
default_ceiling="$h/src/github.com/brunovenceslau/docker-sbx/envs"
mkdir -p "$default_ceiling"   # the guard only fires when this directory exists

# --- a. present -> set to the $HOME/src fallback (CANGA_HOST_BASE_DIR unset) --
out="$(env -i HOME="$h" PATH="$empty" "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"\$GIT_CEILING_DIRECTORIES\"")"
ck "present -> fallback ceiling" "$out" "$default_ceiling"

# --- b. an existing value gets the ceiling PREPENDED, original preserved -----
out="$(env -i HOME="$h" PATH="$empty" GIT_CEILING_DIRECTORIES=/already/there "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"\$GIT_CEILING_DIRECTORIES\"")"
ck "existing value -> ceiling prepended" "$out" "$default_ceiling:/already/there"

# --- c. already the whole value -> unchanged when sourced twice (idempotent) --
out="$(env -i HOME="$h" PATH="$empty" "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  source '$repo_root/zsh/zshenv'
  print -r -- \"\$GIT_CEILING_DIRECTORIES\"")"
ck "double-source stays idempotent, no duplicate entry" "$out" "$default_ceiling"

# --- c2. already present ANYWHERE in an inherited list -> left alone ---------
out="$(env -i HOME="$h" PATH="$empty" GIT_CEILING_DIRECTORIES="/before:$default_ceiling:/after" \
  "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"\$GIT_CEILING_DIRECTORIES\"")"
ck "already present anywhere in the list -> unchanged" "$out" "/before:$default_ceiling:/after"

# --- c3. a NEAR-MISS entry (ceiling as a strict prefix of a longer path) is
# not mistaken for a match - the dedup check is colon-delimited, not substring.
out="$(env -i HOME="$h" PATH="$empty" GIT_CEILING_DIRECTORIES="$default_ceiling-old:/other" \
  "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"\$GIT_CEILING_DIRECTORIES\"")"
ck "near-miss entry does not block the real prepend" "$out" "$default_ceiling:$default_ceiling-old:/other"

# --- d. CANGA_HOST_BASE_DIR is honored over the $HOME/src fallback -----------
canga_ceiling="$work/canga-host/github.com/brunovenceslau/docker-sbx/envs"
mkdir -p "$canga_ceiling"
out="$(env -i HOME="$h" PATH="$empty" CANGA_HOST_BASE_DIR="$work/canga-host" "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"\$GIT_CEILING_DIRECTORIES\"")"
ck "CANGA_HOST_BASE_DIR honored" "$out" "$canga_ceiling"

# --- d2. a RELATIVE CANGA_HOST_BASE_DIR is rejected, even if it happens to
# resolve to a real directory from the shell's own cwd - a relative ceiling
# would make the guard depend on the caller's cwd, never a fixed sandbox path.
# Run with cwd=$work (via a subshell `cd`) so the relative dir it resolves
# against actually exists, proving the rejection is the absolute-path check
# and not just a lookup miss.
mkdir -p "$work/relative-envs/github.com/brunovenceslau/docker-sbx/envs"
out="$(cd "$work" && env -i HOME="$h" PATH="$empty" CANGA_HOST_BASE_DIR="relative-envs" "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"unset=\${+GIT_CEILING_DIRECTORIES}\"")"
ck "relative CANGA_HOST_BASE_DIR -> guard skipped" "$out" "unset=0"

# --- d3. a ceiling containing ':' is rejected - GIT_CEILING_DIRECTORIES is a
# colon-separated list, so a colon in one entry would corrupt every entry
# after it.
colon_base="$work/host:evil"; mkdir -p "$colon_base/github.com/brunovenceslau/docker-sbx/envs"
out="$(env -i HOME="$h" PATH="$empty" CANGA_HOST_BASE_DIR="$colon_base" "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"unset=\${+GIT_CEILING_DIRECTORIES}\"")"
ck "ceiling containing ':' -> guard skipped" "$out" "unset=0"

# --- e. the envs directory is ABSENT -> the variable stays completely untouched
# This is the case a `canga`-on-PATH check cannot cover reliably (zshenv runs
# before zsh/zshrc prepends ~/.local/bin, and a script shell never sources
# zshrc at all - see zsh/zshenv's comment), so the guard gates on the
# directory instead. Can-fail proof: removing `_path_exists -d "$ceiling" ||
# return 0` from zsh/zshenv makes this assertion fail - reverting restores it.
no_envs_home="$work/home-no-envs"; mkdir -p "$no_envs_home"
out="$(env -i HOME="$no_envs_home" PATH="$empty" "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"unset=\${+GIT_CEILING_DIRECTORIES}\"")"
ck "envs directory absent -> GIT_CEILING_DIRECTORIES left unset" "$out" "unset=0"
# ...and a pre-set value is left byte-for-byte alone too, not just "unset".
out="$(env -i HOME="$no_envs_home" PATH="$empty" GIT_CEILING_DIRECTORIES=/pristine "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"\$GIT_CEILING_DIRECTORIES\"")"
ck "envs directory absent -> pre-set value untouched" "$out" "/pristine"

# --- f. the anonymous function's local temporary does not leak ---------------
# ${+ceiling} is 0 whether "ceiling" was never set OR fell out of scope when the
# anonymous function returned; it would read 1 if the block used a `typeset -g`
# (or plain, non-local) assignment instead, so this can actually fail.
out="$(env -i HOME="$h" PATH="$empty" "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"\${+ceiling}\"")"
ck "temporary 'ceiling' does not leak" "$out" "0"

# --- g. _path_exists is a reusable, session-wide utility, not a one-shot -----
# zshenv is the FIRST framework file sourced, so every later file and every
# script needs to see this helper once zshenv has run - it is deliberately
# NOT `unfunction`'d. Checked under both non-interactive and interactive `-c`
# (`-f` keeps the interactive case hermetic too: no real rc file is auto-
# sourced, only the `-o interactive` flag itself is forced on).
# _path_exists' own semantics are covered by tests/path_exists_test.sh, not
# here.
out="$(env -i HOME="$h" PATH="$empty" "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"\${+functions[_path_exists]}\"")"
ck "_path_exists available after sourcing zshenv (non-interactive)" "$out" "1"
out="$(env -i HOME="$h" PATH="$empty" "$zsh_bin" -i -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"\${+functions[_path_exists]}\"" 2>"$work/i.err")" \
  || fail "interactive probe failed: $(cat "$work/i.err")"
ck "_path_exists available after sourcing zshenv (interactive)" "$out" "1"

# --- h. HOME with a space, and HOME with a non-ASCII directory name ----------
# The ceiling is built from $HOME by direct concatenation; both fixtures prove
# the ceiling is assembled byte-for-byte, with no word-splitting or mangling of
# the space or the multibyte characters.
spaced_home="$work/ho me"; mkdir -p "$spaced_home/src/github.com/brunovenceslau/docker-sbx/envs"
out="$(env -i HOME="$spaced_home" PATH="$empty" "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"\$GIT_CEILING_DIRECTORIES\"")"
ck "HOME with a space -> correct ceiling" "$out" "$spaced_home/src/github.com/brunovenceslau/docker-sbx/envs"

unicode_home="$work/hôme-世界"; mkdir -p "$unicode_home/src/github.com/brunovenceslau/docker-sbx/envs"
out="$(env -i HOME="$unicode_home" PATH="$empty" "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"\$GIT_CEILING_DIRECTORIES\"")"
ck "HOME with a non-ASCII name -> correct ceiling" "$out" "$unicode_home/src/github.com/brunovenceslau/docker-sbx/envs"

# --- i. an explicitly empty GIT_CEILING_DIRECTORIES="" leaves no stray ':' ---
# `${GIT_CEILING_DIRECTORIES:+:...}` must treat "set but empty" the same as
# "unset" - a naive `${VAR+:...}` would instead prepend a bare, dangling ':'.
out="$(env -i HOME="$h" PATH="$empty" GIT_CEILING_DIRECTORIES="" "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"\$GIT_CEILING_DIRECTORIES\"")"
ck "empty GIT_CEILING_DIRECTORIES -> no stray ':'" "$out" "$default_ceiling"

# --- 1. sourcing writes NOTHING to stdout or stderr, non-interactively OR ----
# interactively. zshenv runs for every zsh (login, interactive, script), so
# any output here would land in someone else's command output or a script's
# captured stdout. Covers both the fires (envs present) and skips (envs
# absent) branches.
for probe_home in "$h" "$no_envs_home"; do
  outfile="$work/out"; errfile="$work/err"
  env -i HOME="$probe_home" PATH="$empty" "$zsh_bin" -f -c "source '$repo_root/zsh/zshenv'" \
    >"$outfile" 2>"$errfile" || fail "sourcing zshenv exited non-zero (HOME=$probe_home)"
  ck "stdout is empty (HOME=$probe_home)" "$(wc -c <"$outfile" | tr -d ' ')" "0"
  ck "stderr is empty (HOME=$probe_home)" "$(wc -c <"$errfile" | tr -d ' ')" "0"
done
outfile="$work/out"; errfile="$work/err"
env -i HOME="$h" PATH="$empty" "$zsh_bin" -i -f -c "source '$repo_root/zsh/zshenv'" \
  >"$outfile" 2>"$errfile" || fail "sourcing zshenv exited non-zero (interactive)"
ck "stdout is empty (interactive)" "$(wc -c <"$outfile" | tr -d ' ')" "0"
ck "stderr is empty (interactive)" "$(wc -c <"$errfile" | tr -d ' ')" "0"

echo "PASS: git_ceiling_test ($pass assertions)"
