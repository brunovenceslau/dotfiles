# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# tests/lib/bounded_run.sh - run a command that might hang, with a time bound,
# for the tests. Sourced, never run: `make test` globs tests/*.sh only, not
# this dir.
#
# Pure bash plus kill/sleep, never `timeout`/`gtimeout`: macOS ships neither,
# and a new tool is a new dependency (ask first). A tool-availability SKIP
# would be wrong too, since a fixture that guards against a hang must always
# run.
#
# bounded_run BOUND_S OUT CMD... - run CMD with stdin from /dev/null and
#   stdout+stderr into OUT, as its own process group, polled once a second for
#   up to BOUND_S seconds. Sets:
#     br_rc     CMD's exit status (0 when br_hung or br_stuck is set)
#     br_hung   1 when CMD outlived BOUND_S and was killed
#     br_stuck  1 when the group still had its leader BOUND_S seconds after
#               SIGKILL, so it was left unreaped rather than waited on
#   Returns 0 once CMD has run, whatever happened to it; the caller asserts on
#   the three variables. Returns 1, running nothing, when `set -m` did not
#   turn job control on.
#
# Why its own process group: the hung process is usually a grandchild (a
# subshell -> make -> recipe shell -> python3), so killing only $! would
# orphan it. `set -m` gives the background job its own group, and a kill by
# the NEGATIVE pid reaches every member. Measured on bash 3.2.57 (the docker
# bash:3.2 image) and 5.3, non-interactive, with and without a tty: the job's
# pgid equals $!, `kill -TERM -$!` ends the whole group (a grandchild
# included), and `set -m`/`set +m` inside a function under `set -e` leaves the
# caller's other flags alone. The one side effect, a job status line on
# stderr when a killed job is reaped, is silenced below.
#
# Why the in-group sentinel: a group of its own no longer receives the
# signals aimed at the caller's group, so a SIGKILL or a SIGHUP of the test
# script (a CI cancel, a closed terminal) would leave the hung command running
# forever; no trap runs on SIGKILL. The sentinel sits INSIDE the group and
# polls the caller's pid; once the caller is gone it kills the job's group by
# its explicit id, never `kill 0` (the sender's group): should the job ever
# share the caller's group, `kill 0` would take the caller's make and sibling
# suites with it. The id is the job subshell's own pid, read as the PPID of a
# child, since bash 3.2 has no $BASHPID. The `exec` is load-bearing: bash
# 3.2.57 forks a command substitution once more in some contexts (measured
# under `bash -c`), and the PPID is then that fork's. Without job control no
# group has that id, so the kill finds nothing; the `$-` guard refuses to
# start at all in that case. It also exits as soon as CMD does, so a normal
# run leaves nothing behind for more than about a second. Measured: without it, a
# SIGKILLed or SIGHUPed caller leaves the group alive (bash 3.2.57 and 5.3).
# The caller counts as gone once its parent reaps it; a caller left a zombie
# still answers `kill -0`.
#
# Bash 3.2 compatible, like the tests that source it.
# shellcheck shell=bash

br_rc=0
br_hung=0
br_stuck=0
br_pgid=""

bounded_run() {
  local bound="$1" out="$2" caller=$$ elapsed=0 had_m=0
  shift 2
  br_rc=0; br_hung=0; br_stuck=0
  case "$-" in *m*) had_m=1 ;; esac
  set -m
  case "$-" in
    *m*) ;;
    *) echo "bounded_run: set -m did not enable job control - refusing to run" >&2; return 1 ;;
  esac
  (
    self="$(exec sh -c 'echo "$PPID"')"
    "$@" </dev/null >"$out" 2>&1 &
    cmd=$!
    (
      while kill -0 "$caller" 2>/dev/null && kill -0 "$cmd" 2>/dev/null; do sleep 1; done
      # `kill -KILL -1` signals every process the user owns, and -0 is the
      # sender's own group: a pid read that came back empty, non-numeric, 1,
      # or with a leading zero (01 is still 1 to kill) must never reach kill.
      case "$self" in ''|*[!0-9]*|0*|1) exit 1 ;; esac
      if kill -0 "$cmd" 2>/dev/null; then kill -KILL -"$self"; fi
    ) </dev/null >/dev/null 2>&1 &
    wait "$cmd"
  ) &
  br_pgid=$!
  [ "$had_m" = 1 ] || set +m
  # stderr off until the job is reaped: bash prints a job status line for a
  # job killed by a signal (the whole subshell body, several lines), which is
  # noise here, since br_hung already says it happened. Measured: the
  # redirect silences it on bash 3.2.57 and 5.3.
  {
    while kill -0 "$br_pgid" 2>/dev/null; do
      if [ "$elapsed" -ge "$bound" ]; then
        br_hung=1
        # `|| true`: the group can already be gone (TERM alone ended it), and
        # under `set -e` a failed kill would abort the caller before it reports
        # the hang, the one failure this helper exists to surface.
        kill -TERM -"$br_pgid" 2>/dev/null || true
        sleep 1
        kill -KILL -"$br_pgid" 2>/dev/null || true
        break
      fi
      sleep 1
      elapsed=$((elapsed + 1))
    done
    # SIGKILL cannot end a process in uninterruptible sleep (a dead NFS or FUSE
    # mount), and `wait` on one blocks forever. Bash reaps an exited child on
    # SIGCHLD, so `kill -0` turns false once the leader is really gone; `wait`
    # then only collects the status bash already stored.
    elapsed=0
    while kill -0 "$br_pgid" 2>/dev/null; do
      if [ "$elapsed" -ge "$bound" ]; then br_stuck=1; break; fi
      sleep 1
      elapsed=$((elapsed + 1))
    done
    if [ "$br_stuck" = 0 ]; then
      wait "$br_pgid" 2>/dev/null || br_rc=$?
      [ "$br_hung" = 0 ] || br_rc=0
      br_pgid=""
    fi
  } 2>/dev/null
  return 0
}
