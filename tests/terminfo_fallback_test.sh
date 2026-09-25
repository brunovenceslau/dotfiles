#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit test for the terminfo fallback in zsh/zshrc. Reaching a box
# over SSH from a terminal whose terminfo it lacks (e.g. xterm-ghostty) leaves an
# unresolvable $TERM: the zsh line editor doubles typed keystrokes and tmux
# refuses to start. zshrc detects that in-process (the zsh/terminfo module - a
# builtin, no fork) and falls back to xterm-256color. We pin BOTH
# the guard's presence in zshrc AND the underlying mechanism's behaviour.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
rc="$repo_root/zsh/zshrc"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0

# --- the guard lives in zshrc -------------------------------------------------
grep -q 'zmodload zsh/terminfo' "$rc" \
  || fail "zsh/zshrc lost the zsh/terminfo probe (terminfo fallback)"
grep -q '(( ! ${#terminfo} ))' "$rc" \
  || fail "zsh/zshrc lost the empty-terminfo test that gates the fallback"
grep -q 'export TERM=xterm-256color' "$rc" \
  || fail "zsh/zshrc no longer falls back to xterm-256color"
pass=$((pass + 3))

# --- the mechanism: the zsh/terminfo module reports an EMPTY $terminfo for a
# missing entry and a populated one for a real entry, so the guard flips ONLY an
# unresolvable $TERM and leaves a valid one untouched. Run in a pristine `zsh -f`
# so it exercises the mechanism itself, not this host's rc.
if ! command -v zsh >/dev/null 2>&1; then
  if [ -n "${STRICT:-}" ]; then fail "zsh not installed and STRICT=1"; fi
  echo "SKIP: zsh not on PATH - mechanism check skipped"
  echo "PASS: terminfo_fallback_test ($pass assertions)"
  exit 0
fi
guard='if zmodload zsh/terminfo 2>/dev/null && (( ! ${#terminfo} )); then export TERM=xterm-256color; fi; print -r -- $TERM'

got_bogus="$(TERM=bogus-nonexistent-xyz zsh -fc "$guard" 2>/dev/null)"
[ "$got_bogus" = "xterm-256color" ] \
  || fail "an unresolvable TERM was not corrected: got [$got_bogus] want [xterm-256color]"

# vt100 always ships in ncurses-base; it is NOT the fallback, so this proves the
# guard leaves a resolvable terminal alone rather than clobbering everything.
got_valid="$(TERM=vt100 zsh -fc "$guard" 2>/dev/null)"
[ "$got_valid" = "vt100" ] \
  || fail "a resolvable TERM (vt100) was altered: got [$got_valid] want [vt100]"
pass=$((pass + 2))

echo "PASS: terminfo_fallback_test ($pass assertions)"
