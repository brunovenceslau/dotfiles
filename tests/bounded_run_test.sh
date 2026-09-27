#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Tests for tests/lib/bounded_run.sh, the watchdog the hang fixtures in
# tests/py_syntax_test.sh rely on. Those fixtures only reach the watchdog when
# the gate regresses, so without this file its kill, reap and sentinel paths
# would never run on a green tree. Every hang here is REAL: a `cat` blocked
# opening a FIFO nobody writes, never a sleep that ends by itself. Each case
# that could hang this file on a regression runs under bounded_run's own bound
# or inside a harness the outer bounded_run bounds.
set -euo pipefail
set -E
trap '_err_rc=$?; [ "${BASH_SUBSHELL:-0}" -ne 0 ] || echo "ERR: unexpected failure at line $LINENO (rc $_err_rc): $BASH_COMMAND" >&2' ERR

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
lib="$repo_root/tests/lib/bounded_run.sh"
# shellcheck source=tests/lib/bounded_run.sh
. "$lib"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/bounded_run_test.XXXXXX")"
# Any `cat` a failed case left blocked on the FIFO is killed by pid, then the
# scratch dir goes. Signals exit so the EXIT trap runs once.
cleanup() {
  local f
  for f in "$work"/*.pid; do
    if [ -s "$f" ]; then kill -KILL "$(cat "$f")" 2>/dev/null || true; fi
  done
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkfifo "$work/fifo"

# hang_cmd PIDFILE - a command that blocks for good: it records its pid, then
# becomes a `cat` opening a FIFO with no writer. `exec` keeps the pid.
hang_cmd() {
  sh -c 'echo $$ > "$1"; exec cat "$2"' _ "$1" "$work/fifo"
}
# gone_within PID SECONDS - true once PID has exited, polling every 0.2s.
gone_within() {
  local n=0
  while kill -0 "$1" 2>/dev/null; do
    [ "$n" -lt "$(($2 * 5))" ] || return 1
    sleep 0.2
    n=$((n + 1))
  done
}
# wait_pidfile FILE - wait up to 10s for FILE to hold a pid.
wait_pidfile() {
  local n=0
  while [ ! -s "$1" ]; do
    [ "$n" -lt 50 ] || fail "test bug: $1 never got a pid"
    sleep 0.2
    n=$((n + 1))
  done
}

# --- a command that ends on its own: its status and output come back, and
# nothing is flagged.
bounded_run 5 "$work/out" sh -c 'echo hello; exit 7'
[ "$br_rc" = 7 ] && ok || fail "bounded_run must pass the command's exit status through: br_rc=$br_rc"
[ "$br_hung" = 0 ] && [ "$br_stuck" = 0 ] && ok \
  || fail "a command that exits on its own must not be flagged: hung=$br_hung stuck=$br_stuck"
[ "$(cat "$work/out")" = hello ] && ok || fail "bounded_run must capture the command's output: $(cat "$work/out")"

# --- a real hang: flagged within the bound, and the whole group is killed,
# the blocked `cat` (a grandchild of the job) included.
start=$SECONDS
bounded_run 2 "$work/out" hang_cmd "$work/hang.pid"
took=$((SECONDS - start))
[ "$br_hung" = 1 ] && ok || fail "a command blocked on a FIFO must be flagged as hung: hung=$br_hung rc=$br_rc"
[ "$br_stuck" = 0 ] && ok || fail "a hung command that SIGKILL ends must not be flagged as stuck"
# Worst case: 2s of polls, 1s between TERM and KILL, up to 2s more before the
# reap loop sees the leader gone, plus up to 1s of $SECONDS rounding at each end.
[ "$took" -le 8 ] && ok || fail "the hang must be cut off near the 2s bound, took ${took}s"
wait_pidfile "$work/hang.pid"
gone_within "$(cat "$work/hang.pid")" 3 && ok \
  || fail "killing the hung job must reach its grandchild, the blocked cat (pid $(cat "$work/hang.pid"))"

# --- the caller dies (SIGKILL, which no trap sees, and SIGHUP) while the
# bounded command hangs: the in-group sentinel must kill the group. Without
# it the job, in a process group of its own, outlives its caller for good.
# The caller is a fresh bash, so its death is real, not simulated.
for sig in KILL HUP; do
  pidf="$work/caller-$sig.pid"
  bash -c '. "$1"; bounded_run 60 "$2/caller.out" sh -c "echo \$\$ > \"\$0\"; exec cat \"\$1\"" "$3" "$2/fifo"' \
    _ "$lib" "$work" "$pidf" </dev/null >/dev/null 2>&1 &
  caller=$!
  wait_pidfile "$pidf"
  kill -"$sig" "$caller"
  wait "$caller" 2>/dev/null || true
  gone_within "$(cat "$pidf")" 5 && ok \
    || fail "SIG$sig of bounded_run's caller must not orphan the hung command (pid $(cat "$pidf") still alive after 5s)"
done

# --- SIGKILL that does not end the group (a process in uninterruptible
# sleep): bounded_run must give up after the bound and flag it, never block
# in `wait`. Staged by a `kill` function that swallows TERM and KILL, so the
# blocked cat really survives them. The harness is a fresh bash, run under an
# OUTER bounded_run: if bounded_run regressed to an unbounded wait, the outer
# one flags the harness as hung instead of this file hanging.
harness='. "$1"
kill() { case "$1" in -TERM|-KILL) return 0 ;; esac; command kill "$@"; }
bounded_run 2 "$2/stuck.out" sh -c "echo \$\$ > \"\$0\"; exec cat \"\$1\"" "$2/stuck.pid" "$2/fifo"
echo "hung=$br_hung stuck=$br_stuck pgid=$br_pgid"
[ -z "$br_pgid" ] || command kill -KILL -"$br_pgid" 2>/dev/null'
bounded_run 20 "$work/harness.out" bash -c "$harness" _ "$lib" "$work"
[ "$br_hung" = 0 ] && ok \
  || fail "bounded_run must not block in wait on a group SIGKILL cannot end (the harness hung): $(cat "$work/harness.out")"
case "$(cat "$work/harness.out")" in
  *"hung=1 stuck=1 pgid="[0-9]*) ok ;;
  *) fail "a group that survives SIGKILL must be flagged hung and stuck, keeping its pgid: $(cat "$work/harness.out")" ;;
esac

# --- no job control: bounded_run must refuse to run rather than start a job
# that shares its caller's process group, where a group kill would reach the
# caller too. Staged in a fresh bash, itself in a group of its own under the
# outer bounded_run, by a `set` function that swallows -m. The command is a
# marker write, so a regression that runs it anyway kills nothing.
guard='. "$1"
set() { [ "$1" = -m ] && return 0; builtin set "$@"; }
rc=0; bounded_run 5 "$2/guard.out" sh -c ": > \"\$0\"" "$2/guard.ran" || rc=$?
echo "rc=$rc"'
rm -f "$work/guard.ran"
bounded_run 20 "$work/harness.out" bash -c "$guard" _ "$lib" "$work"
[ "$br_hung" = 0 ] || fail "test bug: the no-job-control harness hung: $(cat "$work/harness.out")"
case "$(cat "$work/harness.out")" in
  *"did not enable job control"*"rc=1"*) ok ;;
  *) fail "without job control bounded_run must refuse and return 1: $(cat "$work/harness.out")" ;;
esac
[ ! -e "$work/guard.ran" ] && ok || fail "without job control bounded_run must not run the command"

echo "PASS: bounded_run_test ($pass assertions)"
