#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for zsh/aliases.zsh + zsh/functions.zsh.
# Covers: the alias/function set loads (acceptance: `type mkcd; alias gst`),
# gpf is the --force-with-lease form, mkcd/up behave, and the
# `.local` pair is honoured when present and silent when absent.
#
# The zsh files are exercised in an isolated `zsh -f` (NO_RCS: the tester's real
# ~/.zshenv/.zshrc never load) inside an mktemp workspace, like the other tooling
# tests - the real $HOME is never touched, so this needs no scratch-HOME consent.
# Scope note: this re-encodes zshrc's source order (os.sh -> functions -> aliases)
# rather than sourcing zshrc itself, so a regression in zshrc's OWN ordering or
# its .zshrc.local hook is out of scope here - the full `zsh -i` interactive smoke
# over the real zshrc lands with the CI install smoke.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# zsh is required to source zsh files; `make lint` already depends on it. Skip
# gracefully when it is absent locally, but fail closed under CI (STRICT=1).
if ! command -v zsh >/dev/null 2>&1; then
  if [ -n "${STRICT:-}" ]; then fail "zsh not installed and STRICT=1"; fi
  echo "SKIP: aliases_functions_test (zsh not installed; enforced in CI)"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/aliases_functions_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

export REPO="$repo_root"
export ZDOTDIR="$work/zdotdir"; mkdir -p "$ZDOTDIR"
export FUNC_TMP="$work/func"; mkdir -p "$FUNC_TMP"

# Assertion harness sourced by both runs below. It loads the same three files in
# the same order as zshrc, checks the alias/function surface, then asserts the
# presence ($1 = withlocal) or absence ($1 = nolocal) of markers a `.local` pair
# would define.
cat > "$work/assert.zsh" <<'ZSH'
emulate -L zsh
fail() { print -u2 "FAIL: $1"; exit 1 }

# assert_err CODE DESC CMD... - run CMD in a subshell (so a stray cd cannot leak)
# and assert it exits with CODE and writes something to stderr. Used to pin each
# helper's documented error contract.
assert_err() {
  local want=$1 desc=$2; shift 2
  local err rc
  err=$( ( "$@" ) 2>&1 >/dev/null ); rc=$?
  (( rc == want )) || fail "$desc: exit $rc, wanted $want"
  [[ -n $err ]] || fail "$desc: wrote nothing to stderr"
}

# Same order as zshrc: os.sh, then functions.zsh, then aliases.zsh - so the
# aliases.zsh.local hook can already see the helper functions.
source "$REPO/lib/os.sh"
source "$REPO/zsh/functions.zsh"
source "$REPO/zsh/aliases.zsh"

# --- acceptance: the documented alias/function surface exists -----------------
for a in g gst gd ga gc gp gpf ll la ls ..; do
  (( $+aliases[$a] )) || fail "alias '$a' not defined"
done
for f in mkcd up extract serve gcd; do
  (( $+functions[$f] )) || fail "function '$f' not defined"
done

# gpf must be the lease-guarded force push, never a bare --force.
[[ $aliases[gpf] == *'--force-with-lease'* ]] || fail "gpf is not --force-with-lease: $aliases[gpf]"
[[ $aliases[gpf] == *'--force '* || $aliases[gpf] == *'--force' ]] && fail "gpf uses bare --force"

# serve binds localhost and never falls back to Python 2's SimpleHTTPServer.
[[ $functions[serve] == *'--bind 127.0.0.1'* ]] || fail "serve does not bind 127.0.0.1"
[[ $functions[serve] == *'SimpleHTTPServer'* ]] && fail "serve still references Python 2 SimpleHTTPServer"

# ls colouring: TWO branches, GNU `gls` first and stock BSD ls otherwise.
# Asserting `-G` unconditionally is what the earliest form did, and it fails on
# exactly the hosts this framework targets: a mac with brew's coreutils takes
# the gls branch.
if (( $+commands[gls] )); then
  [[ $aliases[ls] == gls* ]] || fail "gls is present but the ls alias ignores it: $aliases[ls]"
  [[ $aliases[ls] == *'--group-directories-first'* ]] \
    || fail "GNU ls alias lacks --group-directories-first: $aliases[ls]"
else
  [[ $aliases[ls] == *'-G'* ]] || fail "BSD ls alias lacks -G: $aliases[ls]"
fi
# LSCOLORS is the BSD scheme: set whichever branch above won, so a bare
# `\ls -G` stays coloured on a host that also has gls.
[[ -n ${LSCOLORS-} ]] || fail "LSCOLORS unset - BSD ls would be uncoloured"
# $LS_COLORS is the GNU-format palette and MUST be exported on every platform:
# compsys's list-colors (zshrc) reads this format even where BSD ls ignores it.
[[ ${(t)LS_COLORS} == *export* ]] || fail "LS_COLORS is not exported (type: ${(t)LS_COLORS})"
[[ $LS_COLORS == *'di=01;34'* ]]  || fail "LS_COLORS lost the dircolors type entries"
[[ $LS_COLORS == *'*.tar=01;31'* ]] || fail "LS_COLORS lost the per-extension families"

# The listing family + directory-stack aliases (prezto's utility/directory
# modules). `lx` uses GNU-only flags, so it is required only on a GNU-ls host.
for a in ll la l lr lm lk lt lc lu d 1 5 9; do
  (( $+aliases[$a] )) || fail "alias '$a' not defined"
done
if (( $+commands[gls] )); then
  (( $+aliases[lx] )) || fail "alias 'lx' not defined on a GNU-ls host"
fi
# `lc`/`lu` are aliases OF aliases; zsh resolves that chain at command start, so a
# broken link shows up as a missing `ls` prefix once expanded by hand.
[[ $aliases[lt] == 'll -tr' ]] || fail "lt is no longer built on ll: $aliases[lt]"
[[ $aliases[lc] == 'lt -c' ]]  || fail "lc is no longer built on lt: $aliases[lc]"
# `d` and 1..9 are dead without AUTO_PUSHD. That option lives in zshrc, which this
# suite deliberately does not source, so assert the pairing STATICALLY.
grep -q '^setopt AUTO_PUSHD' "$REPO/zsh/zshrc" \
  || fail "zshrc lost AUTO_PUSHD - the d / 1..9 aliases would all be dead"

# --- mkcd: happy path + arg-count guard ---------------------------------------
# `-ef` (same inode) not `==`: macOS's $TMPDIR ends in `/`, so mktemp yields a
# `//` in $FUNC_TMP that zsh collapses out of $PWD on cd - a string compare would
# spuriously fail there while the dirs are in fact identical.
( mkcd "$FUNC_TMP/a/b/c" && [[ $PWD -ef "$FUNC_TMP/a/b/c" ]] ) || fail "mkcd did not create+enter the dir"
assert_err 2 'mkcd rejects zero args' mkcd
assert_err 2 'mkcd rejects two args'  mkcd one two

# --- up: default, explicit, and out-of-range/non-integer contracts ------------
( cd "$FUNC_TMP/a/b/c" && up 2 && [[ $PWD -ef "$FUNC_TMP/a" ]] )   || fail "up 2 did not climb two levels"
( cd "$FUNC_TMP/a/b/c" && up   && [[ $PWD -ef "$FUNC_TMP/a/b" ]] ) || fail "up (no arg) did not climb one level"
assert_err 2 'up rejects zero'          up 0
assert_err 2 'up rejects a non-integer' up abc

# --- extract: leading-dash filename, then the two error contracts -------------
# A leading-dash name would parse as a flag without the ./ guard; prove a real
# round-trip. gzip is near-universal but guarded like the other optional tools.
if (( $+commands[gzip] )); then
  print payload > "$FUNC_TMP/-dash"
  gzip -f "$FUNC_TMP/-dash"                         # -> $FUNC_TMP/-dash.gz
  ( cd "$FUNC_TMP" && extract -dash.gz ) || fail "extract failed on a leading-dash archive"
  [[ -f "$FUNC_TMP/-dash" && ! -f "$FUNC_TMP/-dash.gz" ]] || fail "extract did not unpack the leading-dash archive"
fi
if (( $+commands[tar] )); then
  ( cd "$FUNC_TMP" && print hi > tarme && tar -cf arch.tar tarme && rm tarme \
      && extract arch.tar && [[ -f tarme ]] ) || fail "extract .tar round-trip failed"
fi
assert_err 2 'extract on a missing file'  extract "$FUNC_TMP/does-not-exist.zip"
: > "$FUNC_TMP/mystery.qux"
assert_err 1 'extract on an unknown type' extract "$FUNC_TMP/mystery.qux"

# --- serve: port validation and the no-python guard (no server is started) ----
# Bad ports are rejected before any python probe, so nothing binds. The no-python
# path scrubs PATH in a subshell so both $+commands probes miss and serve returns
# the guard message - again without starting a server.
assert_err 2 'serve rejects a non-integer port' serve abc
assert_err 2 'serve rejects an out-of-range port' serve 70000
sout=$( ( export PATH=/nonexistent-for-test; rehash; serve 8000 ) 2>&1 >/dev/null ); src=$?
(( src == 1 )) || fail "serve without python: exit $src, wanted 1"
[[ $sout == *'needs python3'* ]] || fail "serve without python: wrong/no message ($sout)"

# --- gcd: repo root, subpath, and the outside-a-repo error --------------------
# `-ef` (same inode) not `==`: git's --show-toplevel canonicalizes symlinks, so a
# /tmp -> /private/tmp skew (macOS) must not fail an otherwise-correct cd.
if (( $+commands[git] )); then
  gitrepo="$FUNC_TMP/repo"
  mkdir -p "$gitrepo/sub/dir"
  ( cd "$gitrepo" && git init -q ) >/dev/null 2>&1 || fail "test setup: git init failed"
  ( cd "$gitrepo/sub/dir" && gcd     && [[ $PWD -ef "$gitrepo" ]] )     || fail "gcd did not reach the repo root"
  ( cd "$gitrepo/sub/dir" && gcd sub && [[ $PWD -ef "$gitrepo/sub" ]] ) || fail "gcd SUBPATH did not descend"
  gerr=$( ( cd "$FUNC_TMP" && gcd ) 2>&1 >/dev/null ); grc=$?
  (( grc == 1 )) || fail "gcd outside a git repo: exit $grc, wanted 1"
  [[ -n $gerr ]] || fail "gcd outside a git repo: nothing on stderr"
fi

# --- .local pair honoured when present, silent when absent -----
case $1 in
  withlocal)
    (( $+aliases[__local_marker_alias] ))   || fail "aliases.zsh.local was not sourced"
    (( $+functions[__local_marker_fn] ))    || fail "functions.zsh.local was not sourced"
    # The reorder fix: helpers must exist by the time aliases.zsh.local loads.
    [[ ${__alias_local_saw_helpers-} == 1 ]] || fail "helpers undefined when aliases.zsh.local loaded"
    ;;
  nolocal)
    (( $+aliases[__local_marker_alias] ))   && fail "marker leaked with no .local present"
    (( $+functions[__local_marker_fn] ))    && fail "marker leaked with no .local present"
    ;;
esac
print 'ASSERT-OK'
ZSH

# --- Run 1: no `.local` present - must load cleanly and emit nothing on stderr -
errlog="$work/nolocal.err"
out="$(zsh -f "$work/assert.zsh" nolocal 2>"$errlog")" || fail "assert run (nolocal) exited non-zero: $(cat "$errlog")"
[ "$out" = "ASSERT-OK" ] || fail "nolocal run did not reach ASSERT-OK (got: $out)"
[ -s "$errlog" ] && fail "sourcing with no .local wrote to stderr: $(cat "$errlog")"

# --- Run 2: create the `.local` pair - its definitions must take effect -------
# aliases.zsh.local also records whether the helper functions already exist at
# its load time, proving functions.zsh is sourced first (the reorder fix).
{ printf "alias __local_marker_alias='echo hi'\n"
  printf 'typeset -g __alias_local_saw_helpers=${+functions[mkcd]}\n'
} > "$ZDOTDIR/aliases.zsh.local"
printf '__local_marker_fn() { : }\n' > "$ZDOTDIR/functions.zsh.local"
out="$(zsh -f "$work/assert.zsh" withlocal 2>"$work/withlocal.err")" \
  || fail "assert run (withlocal) exited non-zero: $(cat "$work/withlocal.err")"
[ "$out" = "ASSERT-OK" ] || fail "withlocal run did not reach ASSERT-OK (got: $out)"

echo "PASS: aliases_functions_test"
