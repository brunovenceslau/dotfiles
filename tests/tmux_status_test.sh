#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Tests for bin/tmux-status - the cheap, cost-safe helper
# that feeds the tmux status line's dynamic segments (git branch + a load bar), and
# the SECURITY contract of the status-right wiring in config/tmux/tmux.conf. The
# untrusted pane path MUST NOT be interpolated into the `#(...)` shell context (tmux's
# `#{q:...}` does NOT escape newline/tab, so any directory name is injectable); the
# helper fetches the path from tmux itself over the socket instead. Hermetic: a mktemp
# git fixture with ambient git CONFIG and repo DISCOVERY neutralised. The VISUAL
# render is checked by hand on a mac; nothing here asserts it.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
TS="$repo_root/bin/tmux-status"
conf="$repo_root/config/tmux/tmux.conf"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
# A FIXED expected total (all sources present); the two tool-gated blocks below
# subtract when they legitimately skip. `pass` accumulates only on success, so a
# silently-skipped mandatory block trips the final `pass -eq expected` guard.
expected=26

[ -x "$TS" ] || fail "bin/tmux-status not found or not executable"
command -v git >/dev/null 2>&1 || fail "git required for the branch segment"

work="$(mktemp -d "${TMPDIR:-/tmp}/tmux_status_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Hermetic git: neutralise ambient CONFIG (global/system) AND repo DISCOVERY. A
# `git -C <nonrepo>` walks parent directories, so without a ceiling the "non-repo"
# case picks up an enclosing checkout's branch whenever $TMPDIR sits inside a repo
# (proven: it renders `⎇ ambient/leak` otherwise). GIT_CEILING_DIRECTORIES stops the
# upward walk at the fixture root.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="$work"
export DOTFILES="$repo_root"   # so the helper finds lib/os.sh regardless of cwd
unset TMUX TMUX_PANE 2>/dev/null || true   # so an explicit $1 is the ONLY path source below

run_ts() { # $1 = path arg ; sets OUT, RC (never aborts on the helper's rc)
  set +e
  OUT="$("$TS" "$1" 2>"$work/err")"
  RC=$?
  set -e
}

# --- git branch segment renders in a real repo (hermetic: unborn branch) -------
repo="$work/repo"; mkdir -p "$repo"
( cd "$repo" && git init -q && git branch -m feature/x ) >/dev/null 2>&1
run_ts "$repo"
[ "$RC" -eq 0 ] || fail "helper must exit 0 (in a repo), got $RC (stderr: $(cat "$work/err"))"
case "$OUT" in *"feature/x"*) : ;; *) fail "expected the git branch 'feature/x' in output, got: [$OUT]" ;; esac
pass=$((pass + 2))

# --- detached HEAD renders @<short-sha> (hex), not a branch name ----------------
det="$work/det"; mkdir -p "$det"
( cd "$det" && git init -q \
    && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m x \
    && git checkout -q --detach ) >/dev/null 2>&1
run_ts "$det"
[ "$RC" -eq 0 ] || fail "helper must exit 0 (detached HEAD), got $RC"
case "$OUT" in *"@"[0-9a-f]*) : ;; *) fail "detached HEAD must render an @<hex-sha> segment, got: [$OUT]" ;; esac
pass=$((pass + 2))

# --- degrade: a NON-repo path yields no branch segment, still exit 0 -----------
nonrepo="$work/plain"; mkdir -p "$nonrepo"
run_ts "$nonrepo"
[ "$RC" -eq 0 ] || fail "helper must exit 0 (non-repo), got $RC"
case "$OUT" in *"⎇"*) fail "a non-repo path must NOT render a branch glyph: [$OUT]" ;; esac
pass=$((pass + 2))

# --- load segment: a bar + an integer percentage (format, not a fixed value) ---
run_ts "$nonrepo"
if printf '%s' "$OUT" | LC_ALL=C grep -qE '[0-9]+%'; then
  # FIXED-STRING match on the exact block glyphs the helper emits (U+2588 █ filled /
  # U+2591 ░ empty). A bracket char-class is unsafe: under LC_ALL=C it degrades to a
  # BYTE set and matches the shared 0xe2 lead byte of unrelated glyphs (even ⎇). At
  # low CI load the bar is all ░, so the █-or-░ fallback is load-bearing.
  printf '%s' "$OUT" | LC_ALL=C grep -qF "$(printf '\xe2\x96\x88')" \
    || printf '%s' "$OUT" | LC_ALL=C grep -qF "$(printf '\xe2\x96\x91')" \
    || fail "load percentage present but neither █ nor ░ bar glyph: [$OUT]"
  pass=$((pass + 1))
else
  echo "SKIP: no load source readable here; branch-only degrade verified (rc 0)"
  expected=$((expected - 1))
fi

# --- never errors on a missing / bad path --------------------------------------
run_ts "/no/such/path/$$"
[ "$RC" -eq 0 ] || fail "helper must never error, even on a bad path (got $RC)"
[ -s "$work/err" ] && fail "helper leaked to stderr on a bad path: $(cat "$work/err")"
pass=$((pass + 2))

# --- the helper NEVER shell-executes the path it is given ----------------------
# Defense-in-depth for the self-fetch: even a hostile pane path must reach only
# `git -C "$path"` as a quoted operand, never a shell parser. RED against a helper
# that eval'd or unquoted $path (both payloads execute there).
# shellcheck disable=SC2016  # $(touch ...) is a LITERAL payload, must NOT expand here
h1="$(printf '%s/$(touch %s/PWNED_H1)x' "$work" "$work")"      # command substitution
rm -f "$work/PWNED_H1"; run_ts "$h1"
[ -e "$work/PWNED_H1" ] && fail "helper shell-executed its path arg (command substitution)"
h2="$(printf '%s/boom\ntouch\t%s/PWNED_H2\n:' "$work" "$work")" # newline + tab (the #{q:} gap)
rm -f "$work/PWNED_H2"; run_ts "$h2"
[ -e "$work/PWNED_H2" ] && fail "helper shell-executed its path arg (newline/tab)"
pass=$((pass + 2))

# --- cost discipline: no heavy/sampling subprocess -------------
# Strip comment lines first so the header's own note is not matched.
code="$(LC_ALL=C grep -vE '^[[:space:]]*#' "$TS")"
for bad in 'top ' 'ps aux' 'ps -e' 'vmstat' 'iostat' 'sleep '; do
  if printf '%s\n' "$code" | LC_ALL=C grep -qF "$bad"; then
    fail "cost: bin/tmux-status invokes a heavy/sampling command ('$bad')"
  fi
done
pass=$((pass + 1))

# === status-right wiring is injection-safe by construction =====
# STATIC guards on the SHIPPED tmux.conf. tmux interpolates a `#{...}` format by raw
# text into the `#(...)` /bin/sh command and `#{q:...}` does NOT escape newline/tab,
# so the ONLY safe design is: NO tmux format value inside the `#()` shell body at all
# - the helper fetches the pane path from tmux itself. And the helper path must be
# inlined (a shell var is clobbered to empty by tmux's parse-time $VAR expansion, so
# the helper silently never runs). Both RED against the pre-fix wiring.
sr_line="$(LC_ALL=C grep '^set -g status-right ' "$conf" | LC_ALL=C grep 'tmux-status' | head -1)"
[ -n "$sr_line" ] || fail "could not find the status-right helper line in $conf"
body="${sr_line#*#(}"; body="${body%%)*}"
case "$body" in
  *'#{'*) fail "the status-right #() body interpolates a tmux format (#{...}); the untrusted pane path MUST NOT reach the shell: [$body]" ;;
esac
# shellcheck disable=SC2016  # literal $HOME on purpose: we match the conf's TEXT, not expand it
case "$sr_line" in
  *'test -x $HOME/.local/bin/tmux-status && $HOME/.local/bin/tmux-status'*) : ;;
  *) fail "status-right must inline the linked helper path (\$HOME/.local/bin/tmux-status), not a checkout path or a shell var: [$sr_line]" ;;
esac
pass=$((pass + 2))

# DYNAMIC (tmux-gated): drive the REAL helper inside a live tmux pane via `run-shell`
# (which runs it with the pane's environment, exactly as the status `#()` job does)
# and prove (a) it SELF-FETCHES the pane path from tmux and renders that repo's branch
# - the mechanism that replaced the injectable argument - and (b) a pane whose
# directory name embeds a newline + an injected command creates no marker and no
# error (the fetch-then-`git -C` path cannot execute it). run-shell is deterministic:
# no attached client, no async render capture.
if command -v tmux >/dev/null 2>&1; then
  sock="$work/tmux.sock"
  tmux -L cl24test-$$ kill-server 2>/dev/null || true
  # (a) self-fetch renders the correct branch
  prepo="$work/pane repo"; mkdir -p "$prepo"
  ( cd "$prepo" && git init -q && git branch -m probe/xyz ) >/dev/null 2>&1
  tmux -S "$sock" new-session -d -s s -c "$prepo" -x 80 -y 24 2>/dev/null
  rm -f "$work/dyn.out"
  tmux -S "$sock" run-shell -t s "DOTFILES='$repo_root' GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null '$TS' > '$work/dyn.out' 2>&1"
  dyn="$(cat "$work/dyn.out" 2>/dev/null || true)"
  case "$dyn" in *"probe/xyz"*) : ;; *) fail "helper did not self-fetch the pane path/branch via tmux; got: [$dyn]" ;; esac
  # (b) a malicious pane dir name (newline + a PATH command) must not execute
  printf '#!/bin/sh\ntouch "%s/PWNED_DYN"\n' "$work" > "$work/pwncmd"; chmod u+x "$work/pwncmd"
  evil="$(printf 'boom\npwncmd\n:')"   # slash-free leaf; a newline-separated command
  mkdir -p "$work/wrap"; ( cd "$work/wrap" && mkdir -- "$evil" ) 2>/dev/null || true
  rm -f "$work/PWNED_DYN"
  tmux -S "$sock" new-session -d -s e -c "$work/wrap/$evil" -x 80 -y 24 2>/dev/null
  tmux -S "$sock" run-shell -t e "DOTFILES='$repo_root' PATH='$work:$PATH' '$TS' > '$work/dyn2.out' 2>&1"
  tmux -S "$sock" kill-server 2>/dev/null || true
  [ -e "$work/PWNED_DYN" ] && fail "a malicious pane directory name executed a command through the helper's self-fetch"
  pass=$((pass + 2))
else
  if [ -n "${STRICT:-}" ]; then fail "tmux unavailable and STRICT=1 - status-right self-fetch not exercised"; fi
  echo "SKIP: tmux unavailable - dynamic self-fetch / injection regression not run"
  expected=$((expected - 2))
fi

# --- _bar UNIT coverage: driven DIRECTLY, not through the platform load source ---
# The load block above renders a bar only where the helper HAS a load source (macOS
# sysctl), so off a mac _bar was never exercised at all. Worse, it was barely
# exercised ON one: the caller clamps pct to 0..100 before calling, and real machine
# load never lands on the edges, so the boundary behaviour was untested in CI too.
# Driving the function directly covers glyph selection and the clamp on every
# platform, and costs no new dependency.
#
# _bar is extracted rather than sourced because bin/tmux-status has no main guard -
# sourcing it would run the whole helper. FAIL CLOSED: an extraction that finds no
# function must not pass as "nothing to test" (the exact vacuous-green shape the
# tally guard at the bottom exists to catch).
barsrc="$work/bar.sh"
sed -n '/^_bar() {/,/^}/p' "$TS" > "$barsrc"
grep -q '^_bar() {' "$barsrc" \
  || fail "could not extract _bar from $TS (renamed or reshaped?) - the unit block would pass vacuously"
# shellcheck source=/dev/null
. "$barsrc"

FULL="$(printf '\xe2\x96\x88')"   # U+2588 FULL BLOCK
EMPTY="$(printf '\xe2\x96\x91')"  # U+2591 LIGHT SHADE
ck_bar() { # $1 = input, $2 = expected 5-cell rendering
  local got; got="$(_bar "$1")"
  [ "$got" = "$2" ] || fail "_bar($1): expected [$2], got [$got]"
  pass=$((pass + 1))
}
# filled = pct * 5 / 100 (integer), so the cell boundaries sit every 20 points.
ck_bar 0   "$EMPTY$EMPTY$EMPTY$EMPTY$EMPTY"
ck_bar 19  "$EMPTY$EMPTY$EMPTY$EMPTY$EMPTY"   # just below the first cell
ck_bar 20  "$FULL$EMPTY$EMPTY$EMPTY$EMPTY"    # exactly one cell
ck_bar 50  "$FULL$FULL$EMPTY$EMPTY$EMPTY"
ck_bar 99  "$FULL$FULL$FULL$FULL$EMPTY"       # just below full
ck_bar 100 "$FULL$FULL$FULL$FULL$FULL"
# Over 100 saturates instead of overflowing the bar. Unreachable from the helper
# (the caller clamps first), so this pins _bar's OWN contract for a direct caller.
ck_bar 120 "$FULL$FULL$FULL$FULL$FULL"
# Non-integer input degrades to 0 rather than erroring under `set -u` arithmetic.
ck_bar ""    "$EMPTY$EMPTY$EMPTY$EMPTY$EMPTY"
ck_bar "abc" "$EMPTY$EMPTY$EMPTY$EMPTY$EMPTY"
# A negative is caught by that same non-digit guard BEFORE the arithmetic, which is
# why _bar's `filled -lt 0` branch is unreachable: `-` never survives the case.
ck_bar "-5"  "$EMPTY$EMPTY$EMPTY$EMPTY$EMPTY"

[ "$pass" -eq "$expected" ] || fail "assertion tally mismatch: ran $pass, expected $expected (a block was silently skipped)"
echo "ok   tmux_status_test.sh ($pass assertions)"
