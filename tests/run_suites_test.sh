#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Tests for tests/run_suites.py, the runner `make test` execs: suites run
# several at a time, each under its own TMPDIR behind a symlink, with output
# buffered per suite, every failure named, serial suites alone, process groups
# stopped (TERM, then KILL) on a signal, and the scratch root removed on every
# exit path. Each case runs the real runner over fixture suites written into a
# scratch directory, under a TMPDIR of its own, so "nothing left behind" is a
# plain `ls -A`. Concurrency is proven with barriers (each suite waits until
# all of them have started), never with timings, so a slow machine cannot turn
# a case red. The timing checks are lower bounds, an order between two
# suites' times, and upper bounds far above what they bound (a 0.3 s reap
# bound must hold within 5 s). Every runner call is bounded, so a runner that
# hangs fails the case instead of stalling the suite. A fixture that ignores
# TERM loops for 60 s at most, so a case cut short cannot leave it running
# for ever. tests/make_test_env_scrub_test.sh holds the recipe's side: the
# git env scrub, TMPDIR made absolute, the 129/130/131/143 exits as make
# reports them.
set -euo pipefail
set -E
trap '_err_rc=$?; [ "${BASH_SUBSHELL:-0}" -ne 0 ] || echo "ERR: unexpected failure at line $LINENO (rc $_err_rc): $BASH_COMMAND" >&2' ERR

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runner="$repo_root/tests/run_suites.py"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); }
# shellcheck source=tests/lib/bounded_run.sh
. "$repo_root/tests/lib/bounded_run.sh"

if ! py="$(command -v python3)"; then
  [ -z "${STRICT:-}" ] || fail "python3 not found and STRICT=1 - the runner cannot be tested"
  echo "SKIP: run_suites_test (python3 not found)"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/run_suites_test.XXXXXX")"
# inner_leader is set only while case 6c's inner suite, which sits in a
# session no runner here can reach once its own runner is gone, may run.
inner_leader=""
trap '[ -z "$inner_leader" ] || kill -KILL "$inner_leader" 2>/dev/null || true; rm -rf "$work"' EXIT
# On a signal, stop the runners this file started, and wait for them, before
# exiting: a runner keeps its suites in sessions of their own, so only the
# runner itself can stop them, and one cut short leaves them running forever.
# A runner from start_bg shares this file's process group, so a signal sent
# to the group has reached it already; the TERM sent here is its second
# signal, which skips its grace period. One under bounded_run has a group of
# its own and gets both TERMs from here, 0.2s apart: two identical signals
# arriving together reach a Python handler once.
rpid=""
forward() {
  local i=0
  if [ -n "$rpid" ]; then
    kill -TERM "$rpid" 2>/dev/null || true; sleep 0.2; kill -TERM "$rpid" 2>/dev/null || true
    while kill -0 "$rpid" 2>/dev/null && [ "$i" -lt 300 ]; do i=$((i + 1)); sleep 0.1; done
  fi
  i=0
  if [ -n "${br_pgid:-}" ]; then
    kill -TERM -"$br_pgid" 2>/dev/null || true; sleep 0.2; kill -TERM -"$br_pgid" 2>/dev/null || true
    while kill -0 -"$br_pgid" 2>/dev/null && [ "$i" -lt 300 ]; do i=$((i + 1)); sleep 0.1; done
  fi
  exit "$1"
}
trap 'forward 129' HUP
trap 'forward 130' INT
trap 'forward 131' QUIT
trap 'forward 143' TERM

# fresh - a new suite directory ($s), shared state directory ($SHARED, which
# the suites see) and TMPDIR parent ($tp) for one case.
n=0
fresh() {
  n=$((n + 1))
  s="$work/c$n/suites"; SHARED="$work/c$n/shared"; tp="$work/c$n/tp"
  mkdir -p "$s" "$SHARED" "$tp"
  export SHARED
}
# suite NAME BODY - a fixture suite in $s.
suite() { printf '#!/usr/bin/env bash\nset -u\n%s\n' "$2" > "$s/$1"; }
# run JOBS SUITE... - the runner from $s with TEST_JOBS=JOBS and TMPDIR=$tp,
# plus the assignments in the array extra_env, stdin from $RUN_STDIN (default
# /dev/null), bounded at 60s; stdout in $out, stderr in $err, exit code in $rc.
extra_env=()
run() {
  local jobs="$1"
  shift
  bounded_run 60 "$work/err" sh -c 'cd "$1" && shift && exec "$@" > "$0" < "${RUN_STDIN:-/dev/null}"' \
    "$work/out" "$s" env TEST_JOBS="$jobs" TMPDIR="$tp" ${extra_env[@]+"${extra_env[@]}"} \
    "$py" -I "$runner" "$@"
  out="$(cat "$work/out")"; err="$(cat "$work/err")"
  [ "$br_hung" = 0 ] && [ "$br_stuck" = 0 ] || fail "the runner hung (bound 60s): $out $err"
  rc="$br_rc"
}
empty_tp() { [ -z "$(ls -A "$tp")" ]; }
# A barrier: the suite marks itself started and waits, up to 30s, until N
# suites have. It passes only when N of them were running at the same time.
barrier() {
  printf ': > "$SHARED/started.%s"\ni=0\nwhile [ "$(ls "$SHARED" | grep -c "^started\\.")" -lt %s ]; do\n  i=$((i + 1)); [ "$i" -le 300 ] || { echo "BARRIER TIMEOUT"; exit 9; }\n  sleep 0.1\ndone\n' "$1" "$2"
}
# gone PID SECS - true once PID has exited, false if it still runs after SECS.
gone() {
  local i=0
  while kill -0 "$1" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -le $(($2 * 10)) ] || return 1
    sleep 0.1
  done
}
# wait_file PATH - wait up to 30s for PATH to exist and be non-empty.
wait_file() {
  local i=0
  while [ ! -s "$1" ]; do
    i=$((i + 1)); [ "$i" -le 300 ] || return 1
    sleep 0.1
  done
}
# block FILE OUTPUT - the lines of FILE's block, from `run FILE` to its `done`.
block() { awk -v f="$1" '$0 == "run " f { p = 1 } p { print } p && index($0, "done " f ": ") == 1 { exit }' <<<"$2"; }
now() { "$py" -I -c 'import time; print("%.3f" % time.time())'; }
# The body of a fixture that ignores TERM: 600 sleeps of 0.1 s, so one left
# behind by a case cut short ends by itself within about a minute.
deaf_loop='i=0; while [ "$i" -lt 600 ]; do i=$((i + 1)); sleep 0.1; done'

# --- 1. Several at a time: three suites pass a three-way barrier, so all ran
# at once; each `start` line precedes its block; every block is opened by
# `run` and closed by `done`; the times are listed slowest first; the last
# line is the one `make test` always printed.
fresh
suite a.sh "$(barrier a 3)
echo A-OUT"
suite b.sh "$(barrier b 3)
sleep 1
echo B-OUT"
suite c.sh "$(barrier c 3)
echo C-OUT"
run 3 a.sh b.sh c.sh
[ "$rc" = 0 ] && ok || fail "three suites must pass a three-way barrier at TEST_JOBS=3 (rc $rc): $out $err"
for f in a b c; do
  grep -qx "run $f.sh" <<<"$out" && ok || fail "the $f.sh block must open with 'run $f.sh': $out"
  grep -q "^done $f\\.sh: ok in [0-9.]*s, peak RSS [0-9]* MiB\$" <<<"$out" && ok \
    || fail "the $f.sh block must close with its verdict, time and peak RSS: $out"
  st="$(grep -nx "start $f.sh" <<<"$out" | cut -d: -f1 || true)"; rn="$(grep -nx "run $f.sh" <<<"$out" | cut -d: -f1 || true)"
  [ -n "$st" ] && [ "$st" -lt "$rn" ] && ok || fail "a 'start $f.sh' line must come before its block: $out"
done
[ "$(tail -n 1 <<<"$out")" = "test: all 3 test files passed" ] && ok \
  || fail "the last line must be 'test: all 3 test files passed': $out"
first="$(sed -n '/slowest first:$/{n;p;}' <<<"$out")"
case "$first" in
  *" b.sh") ok ;;
  *) fail "the slowest suite (b.sh) must head the time summary, got '$first': $out" ;;
esac
grep -q "^test: 3 suites (0 serial), 3 at a time (TEST_JOBS=3)\$" <<<"$out" && ok \
  || fail "the header must say how many suites run at once and why: $out"
empty_tp && ok || fail "the scratch root must be removed after a pass: $(ls -A "$tp")"

# --- 2. Keep going: every suite runs, every failure is named on stderr in
# list order, a passing suite between them does not hide one, exit is 1, and
# a failing suite's own stderr is printed inside its own block.
fresh
suite a_fail.sh 'echo A; echo A-ERR-MARK >&2; exit 1'
suite b_ok.sh 'echo B'
suite c_fail.sh 'echo C; echo C-ERR-MARK >&2; exit 3'
run 1 a_fail.sh b_ok.sh c_fail.sh
[ "$rc" = 1 ] && ok || fail "a failing suite must make the runner exit 1 (rc $rc): $out $err"
grep -qx "test: FAILED: a_fail.sh c_fail.sh" <<<"$err" && ok \
  || fail "stderr must name every failed suite, in list order: $err"
grep -qx "done c_fail.sh: FAILED (exit 3) in [0-9.]*s, peak RSS [0-9]* MiB" <<<"$out" && ok \
  || fail "a suite after a failure must still run and report its own exit code: $out"
grep -qx "C-ERR-MARK" <<<"$(block c_fail.sh "$out")" && ok \
  || fail "a suite's stderr must be printed inside its own block: $out"
grep -qx "run b_ok.sh" <<<"$out" && ok || fail "a passing suite between failures must run: $out"
grep -q "all 3 test files passed" <<<"$out" && fail "a failed run must not claim a pass: $out" || ok
empty_tp && ok || fail "the scratch root must be removed after a failure: $(ls -A "$tp")"

# --- 3. Output never interleaves: two suites print at the same time (the
# barrier holds them together), yet each block holds only its own lines.
fresh
noisy() {
  printf '%s\ni=0\nwhile [ "$i" -lt 200 ]; do\n  echo "%s line $i"; echo "%s err $i" >&2\n  i=$((i + 1)); [ $((i %% 20)) -ne 0 ] || sleep 0.01\ndone\n' \
    "$(barrier "$1" 2)" "$1" "$1"
}
suite x.sh "$(noisy X)"
suite y.sh "$(noisy Y)"
run 2 x.sh y.sh
[ "$rc" = 0 ] && ok || fail "two noisy suites must pass (rc $rc): $out $err"
bad="$(awk '
  /^run / { cur = substr($2, 1, 1); next }
  /^done / { cur = ""; next }
  /^[XY] / { if (toupper(substr($1, 1, 1)) != toupper(cur)) print NR ": " $0 }
' <<<"$out")"
[ -z "$bad" ] && ok || fail "a suite line landed outside its own block: $(head -n 3 <<<"$bad")"
[ "$(grep -c '^X ' <<<"$out")" = 400 ] && [ "$(grep -c '^Y ' <<<"$out")" = 400 ] && ok \
  || fail "every stdout and stderr line of both suites must be printed: $out"

# --- 4. TEST_JOBS=1 runs one suite at a time: each takes a lock directory a
# second suite running alongside could not take.
fresh
for f in p q r; do suite "$f.sh" 'mkdir "$SHARED/lock" || { echo OVERLAP; exit 8; }
sleep 0.2
rmdir "$SHARED/lock"'; done
run 1 p.sh q.sh r.sh
[ "$rc" = 0 ] && ok || fail "TEST_JOBS=1 must run the suites one at a time (rc $rc): $out"
grep -q "1 at a time (TEST_JOBS=1)" <<<"$out" && ok || fail "the header must report TEST_JOBS=1: $out"

# --- 5. Each suite gets its own TMPDIR: absolute, a directory, behind one
# shared symlink (its physical path differs), distinct from every other.
fresh
for f in t1 t2 t3; do suite "$f.sh" "$(barrier "$f" 3)
printf '%s\n' \"\$TMPDIR\" > \"\$SHARED/tmpdir.$f\"
cd -P \"\$TMPDIR\" && pwd -P > \"\$SHARED/phys.$f\"
mktemp \"\$TMPDIR/x.XXXXXX\" >/dev/null"; done
run 3 t1.sh t2.sh t3.sh
[ "$rc" = 0 ] && ok || fail "the TMPDIR probes must pass (rc $rc): $out $err"
dirs="$(cat "$SHARED"/tmpdir.*)"
[ "$(sort -u <<<"$dirs" | wc -l | tr -d ' ')" = 3 ] && ok \
  || fail "three suites must get three distinct TMPDIRs: $dirs"
parents="$(while IFS= read -r d; do dirname "$d"; done <<<"$dirs" | sort -u)"
[ "$(wc -l <<<"$parents" | tr -d ' ')" = 1 ] && ok || fail "every TMPDIR must sit in one scratch root: $parents"
# The runner resolves its root to a physical path, so compare against the
# caller's TMPDIR resolved the same way: under `make test` it is itself behind
# a link.
tp_phys="$(cd -P "$tp" && pwd -P)"
case "$parents" in
  "$tp_phys"/*) ok ;;
  *) fail "the scratch root must be under the caller's TMPDIR ($tp_phys): $parents" ;;
esac
for f in t1 t2 t3; do
  d="$(cat "$SHARED/tmpdir.$f")"; p="$(cat "$SHARED/phys.$f")"
  [ "$d" != "$p" ] && ok || fail "$f.sh's TMPDIR must resolve elsewhere (behind a link): $d"
done
# The parent recorded above no longer exists, so the link is checked by its
# name: the runner's layout is <root>/link -> real.
[ "$(basename "$parents")" = link ] && ok || fail "the shared parent must be the root's link: $parents"
empty_tp && ok || fail "the scratch root must be removed with every suite's TMPDIR: $(ls -A "$tp")"

# start_bg JOBS SUITE... - the runner in the background (its pid in $rpid),
# output in $work/out, for the signal cases.
start_bg() {
  local jobs="$1"
  shift
  (cd "$s" && exec env TEST_JOBS="$jobs" TMPDIR="$tp" ${extra_env[@]+"${extra_env[@]}"} \
    "$py" -I "$runner" "$@") < /dev/null > "$work/out" 2>&1 &
  rpid=$!
}
# finish SECS - wait up to SECS for the background runner; its exit code in $rc.
finish() {
  gone "$rpid" "$1" || { kill -KILL "$rpid" 2>/dev/null || true; rpid=""; fail "the runner did not exit within $1s: $(cat "$work/out")"; }
  rc=0; wait "$rpid" || rc=$?
  rpid=""
}

# --- 6. A signal stops every running suite, its own children included (one
# that ignores TERM too), prints each stopped suite's output with an
# INTERRUPTED verdict, removes the scratch root, and exits 128+N.
for sig in HUP:129 INT:130 QUIT:131 TERM:143; do
  code="${sig#*:}"; sig="${sig%:*}"
  fresh
  suite slow.sh 'echo SLOW-OUT
sleep 300 &
echo "$!" > "$SHARED/child.pid"
( trap "" TERM; exec sleep 300 ) &
echo "$!" > "$SHARED/ignorer.pid"
wait'
  suite other.sh 'echo OTHER-OUT; echo ready > "$SHARED/other.ready"; sleep 300'
  # The TERM-ignoring child keeps the group alive for the whole grace
  # period: 1s keeps the case short.
  extra_env=(RUN_SUITES_GRACE_SECONDS=1)
  start_bg 2 slow.sh other.sh
  extra_env=()
  wait_file "$SHARED/ignorer.pid" || { kill -KILL "$rpid" 2>/dev/null || true; fail "test bug: slow.sh never started ($sig)"; }
  # other.sh has printed OTHER-OUT once it marks itself ready.
  wait_file "$SHARED/other.ready" || { kill -KILL "$rpid" 2>/dev/null || true; fail "test bug: other.sh never started ($sig)"; }
  kill -"$sig" "$rpid"
  finish 30
  out="$(cat "$work/out")"
  [ "$rc" = "$code" ] && ok || fail "$sig must make the runner exit $code, got $rc: $out"
  grep -q "test: interrupted by SIG$sig" <<<"$out" && ok || fail "the runner must say it was interrupted by $sig: $out"
  for f in slow other; do
    b="$(block "$f.sh" "$out")"
    grep -qx "$(tr '[:lower:]' '[:upper:]' <<<"$f")-OUT" <<<"$b" && ok \
      || fail "$sig: the stopped $f.sh block must hold its output: $out"
    grep -q "^done $f.sh: INTERRUPTED (by SIG$sig) in " <<<"$b" && ok \
      || fail "$sig: the stopped $f.sh must be reported INTERRUPTED: $out"
  done
  empty_tp && ok || fail "$sig must leave no scratch root behind: $(ls -A "$tp")"
  for p in child ignorer; do
    pid="$(cat "$SHARED/$p.pid")"
    gone "$pid" 10 && ok || { kill -KILL "$pid" 2>/dev/null || true; fail "$sig must stop a suite's $p process too (pid $pid alive)"; }
  done
done

# --- 6b. A suite whose main process ignores TERM gets TERM first and KILL
# only once the grace period is over.
fresh
suite stubborn.sh "trap 'echo TERM > \"\$SHARED/got-term\"' TERM
echo \"\$\$\" > \"\$SHARED/leader.pid\"
$deaf_loop"
extra_env=(RUN_SUITES_GRACE_SECONDS=2)
start_bg 1 stubborn.sh
extra_env=()
wait_file "$SHARED/leader.pid" || { kill -KILL "$rpid" 2>/dev/null || true; fail "test bug: stubborn.sh never started"; }
t0="$(now)"
kill -TERM "$rpid"
finish 30
t1="$(now)"
[ "$rc" = 143 ] && ok || fail "a TERM-ignoring suite must still end the run with 143 (rc $rc): $(cat "$work/out")"
[ -e "$SHARED/got-term" ] && ok || fail "the suite must get TERM before KILL: $(cat "$work/out")"
awk -v a="$t0" -v b="$t1" 'BEGIN { exit !(b - a >= 2) }' && ok \
  || fail "KILL must wait for the 2s grace period (took $t0 -> $t1)"
gone "$(cat "$SHARED/leader.pid")" 10 && ok || fail "the TERM-ignoring suite must be KILLed after the grace period"
# A second signal skips the rest of the grace period.
fresh
suite stubborn.sh "trap 'echo TERM > \"\$SHARED/got-term\"' TERM
echo \"\$\$\" > \"\$SHARED/leader.pid\"
$deaf_loop"
extra_env=(RUN_SUITES_GRACE_SECONDS=120)
start_bg 1 stubborn.sh
extra_env=()
wait_file "$SHARED/leader.pid" || { kill -KILL "$rpid" 2>/dev/null || true; fail "test bug: stubborn.sh never started"; }
kill -TERM "$rpid"
wait_file "$SHARED/got-term" || { kill -KILL "$rpid" 2>/dev/null || true; fail "test bug: the suite never got the first TERM"; }
kill -TERM "$rpid"
finish 30
[ "$rc" = 143 ] && ok || fail "a second signal must end the run at once with 143 (rc $rc): $(cat "$work/out")"
gone "$(cat "$SHARED/leader.pid")" 10 && ok || fail "a second signal must KILL the TERM-ignoring suite"

# --- 6c. A suite that runs a nested runner: on a signal, the outer runner
# waits for the suite's whole group, not only its main process, so the inner
# runner (in that group) has time to stop its own suites, which sit in
# sessions of their own. KILLing the group as soon as the main process
# exited would leave the inner suite running forever, orphaned.
fresh
mkdir -p "$SHARED/inner" "$SHARED/itp"
printf '#!/usr/bin/env bash\ntrap "echo TERM > \\"\\$SHARED/got-term\\"" TERM\necho "$$" > "$SHARED/leader.pid"\n%s\n' "$deaf_loop" \
  > "$SHARED/inner/stubborn.sh"
suite nest.sh 'cd "$SHARED/inner" || exit 1
RUN_SUITES_GRACE_SECONDS=1 TEST_JOBS=1 TMPDIR="$SHARED/itp" "$PY" -I "$RUNNER" stubborn.sh > "$SHARED/inner.log" 2>&1 &
wait'
extra_env=(RUN_SUITES_GRACE_SECONDS=30 PY="$py" RUNNER="$runner")
start_bg 1 nest.sh
extra_env=()
wait_file "$SHARED/leader.pid" || { kill -KILL "$rpid" 2>/dev/null || true; fail "test bug: the inner suite never started: $(cat "$work/out")"; }
inner_leader="$(cat "$SHARED/leader.pid")"
kill -TERM "$rpid"
finish 40
[ "$rc" = 143 ] && ok || fail "the outer runner must exit 143 (rc $rc): $(cat "$work/out")"
gone "$inner_leader" 10 && ok \
  || fail "an interrupted nested runner must not orphan its suite (pid $inner_leader alive): $(cat "$SHARED/inner.log")"
inner_leader=""
grep -q "test: interrupted by SIGTERM" "$SHARED/inner.log" && ok \
  || fail "the inner runner must get to stop its own suites: $(cat "$SHARED/inner.log")"
[ -z "$(ls -A "$SHARED/itp")" ] && ok || fail "the inner runner must remove its scratch root: $(ls -A "$SHARED/itp")"

# --- 6d. An INTERRUPTED suite's time runs until its main process ended: one
# that obeys TERM is not charged the grace period, one that ignores it is.
# An order between the two, not a bound, so load cannot turn it red.
fresh
suite obey.sh 'echo ready > "$SHARED/obey.ready"; sleep 300'
suite deaf.sh "trap '' TERM
echo ready > \"\$SHARED/deaf.ready\"
$deaf_loop"
extra_env=(RUN_SUITES_GRACE_SECONDS=3)
start_bg 2 obey.sh deaf.sh
extra_env=()
for f in obey deaf; do
  wait_file "$SHARED/$f.ready" || { kill -KILL "$rpid" 2>/dev/null || true; fail "test bug: $f.sh never started"; }
done
kill -TERM "$rpid"
finish 30
out="$(cat "$work/out")"
secs() { sed -n "s/^done $1: INTERRUPTED (by SIGTERM) in \([0-9.]*\)s, .*/\1/p" <<<"$out"; }
t_obey="$(secs obey.sh)"; t_deaf="$(secs deaf.sh)"
[ -n "$t_obey" ] && [ -n "$t_deaf" ] || fail "both suites must be reported INTERRUPTED with a time: $out"
awk -v a="$t_obey" -v b="$t_deaf" 'BEGIN { exit !(a < b) }' && ok \
  || fail "a suite that obeys TERM must not be charged the grace period (obey ${t_obey}s, deaf ${t_deaf}s): $out"

# --- 7. Serial suites run alone and before the pool: no pool suite is
# running while one runs, and every pool suite starts after it ended.
fresh
pool='[ -e "$SHARED/serial.done" ] || { echo "POOL BEFORE SERIAL"; exit 5; }
: > "$SHARED/running.$$"
i=0; while [ "$i" -lt 3 ]; do [ ! -e "$SHARED/serial.on" ] || exit 7; i=$((i + 1)); sleep 0.1; done
rm -f "$SHARED/running.$$"'
suite p1.sh "$pool"
suite p2.sh "$pool"
suite p3.sh "$pool"
suite s1.sh '# run_suites: serial
running() { [ "$(ls "$SHARED" | grep -c "^running\.")" -gt 0 ]; }
! running || { echo "POOL RUNNING AT START"; exit 6; }
: > "$SHARED/serial.on"; sleep 0.5
! running || { echo "POOL RUNNING DURING"; exit 6; }
rm -f "$SHARED/serial.on"; : > "$SHARED/serial.done"'
run 4 p1.sh s1.sh p2.sh p3.sh
[ "$rc" = 0 ] && ok || fail "a serial suite must run alone, before the pool (rc $rc): $out $err"
grep -q "^test: 4 suites (1 serial), 4 at a time" <<<"$out" && ok || fail "the header must count the serial suite: $out"
# The marker must be the whole line: a mention of it, or the marker with
# more text after it, does not make a suite serial.
fresh
suite s1.sh "$(barrier s1 2)
echo 'not a marker: # run_suites: serial'"
suite s2.sh "# run_suites: serial extra
$(barrier s2 2)"
run 2 s1.sh s2.sh
[ "$rc" = 0 ] && ok || fail "suites only mentioning the marker must stay in the pool (rc $rc): $out"

# --- 8. No suites: the message `make test` always printed, exit 0, nothing made.
fresh
run 1
[ "$rc" = 0 ] && [ "$out" = "test: no tests found" ] && ok \
  || fail "an empty list must print 'test: no tests found' and exit 0 (rc $rc): $out"
empty_tp && ok || fail "an empty list must make no scratch root: $(ls -A "$tp")"

# --- 9. Fail closed: a bad TEST_JOBS or grace period, or an unusable TMPDIR,
# stops the run before any suite starts.
for bad in 0 abc -1 "2 " 1.5 10000; do
  fresh
  suite m.sh ': > "$SHARED/ran"'
  run "$bad" m.sh
  [ "$rc" = 1 ] && ok || fail "TEST_JOBS='$bad' must fail closed (rc $rc): $out $err"
  grep -q "^ERROR: test: TEST_JOBS must be a positive integer" <<<"$err" && ok \
    || fail "TEST_JOBS='$bad' must say why: $err"
  [ ! -e "$SHARED/ran" ] && ok || fail "no suite may run with TEST_JOBS='$bad'"
done
for bad in -1 1000 1234.5 1.2345 abc; do
  fresh
  suite m.sh ': > "$SHARED/ran"'
  extra_env=(RUN_SUITES_GRACE_SECONDS="$bad")
  run 1 m.sh
  extra_env=()
  [ "$rc" = 1 ] && grep -q "^ERROR: test: RUN_SUITES_GRACE_SECONDS must be" <<<"$err" && [ ! -e "$SHARED/ran" ] && ok \
    || fail "the grace period '$bad' must fail closed before any suite runs (rc $rc): $err"
done
fresh
suite m.sh ': > "$SHARED/ran"'
tp="$work/missing"
run 1 m.sh
[ "$rc" = 1 ] && ok || fail "a missing TMPDIR must fail closed (rc $rc): $out $err"
grep -q "^ERROR: test: could not make the scratch root" <<<"$err" && ok \
  || fail "a missing TMPDIR must be named as the reason: $err"
[ ! -e "$SHARED/ran" ] && ok || fail "no suite may run without a scratch root"

# --- 10. The default job count: min(CPUs, available memory / the per-suite
# budget), at least 1, the Linux meminfo and macOS vm_stat readings, and the
# peak RSS units
# (KiB on Linux, bytes on macOS). Pure functions, so checked here on every
# platform. -B: importing the runner must not write tests/__pycache__ into
# the checkout while other suites copy it.
: > "$work/units.stamp"
units="$("$py" -I -B - "$runner" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("run_suites", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
mib = 1024 * 1024
b = m.SUITE_MEMORY_MIB * mib
class RU:
    ru_maxrss = 0
linux, darwin = RU(), RU()
linux.ru_maxrss = 300 * 1024          # KiB
darwin.ru_maxrss = 300 * mib          # bytes
checks = [
    ("memory caps the CPUs", m.pick_jobs(10, 3 * b), 3),
    ("CPUs cap the memory", m.pick_jobs(4, 100 * b), 4),
    ("never below 1", m.pick_jobs(10, b // 2), 1),
    ("no memory reading: CPUs decide", m.pick_jobs(6, None), 6),
    ("vm_stat pages", m.parse_vm_stat(
        "Mach Virtual Memory Statistics: (page size of 16384 bytes)\n"
        "Pages free:                               1000.\n"
        "Pages active:                             9999.\n"
        "Pages inactive:                            200.\n"
        "Pages speculative:                          30.\n"), 1230 * 16384),
    ("vm_stat without a page size", m.parse_vm_stat("Pages free: 1.\n"), None),
    ("vm_stat without a count", m.parse_vm_stat("(page size of 4096 bytes)\nPages free: 1.\n"), None),
    ("meminfo KiB", m.parse_meminfo(
        "MemTotal:       16000000 kB\n"
        "MemFree:          100000 kB\n"
        "MemAvailable:    8000000 kB\n"
        "Buffers:           50000 kB\n"), 8000000 * 1024),
    ("meminfo without MemAvailable", m.parse_meminfo("MemTotal: 16000000 kB\nMemFree: 1 kB\n"), None),
    ("meminfo with a malformed count", m.parse_meminfo("MemAvailable:   12x34 kB\n"), None),
    ("peak RSS on Linux (KiB)", m.peak_rss_mib(linux, "linux"), 300),
    ("peak RSS on macOS (bytes)", m.peak_rss_mib(darwin, "darwin"), 300),
]
for name, got, want in checks:
    print("%s %s: got %r, want %r" % ("ok" if got == want else "BAD", name, got, want))
PY
)"
grep -q '^BAD' <<<"$units" && fail "job count units: $(grep '^BAD' <<<"$units")" || ok
[ "$(grep -c '^ok' <<<"$units")" = 12 ] && ok || fail "test bug: the units did not all run: $units"
[ -z "$(find "$repo_root/tests" -name '__pycache__' -prune -newer "$work/units.stamp" -print 2>/dev/null)" ] && \
  [ -z "$(find "$repo_root/tests" -path '*/__pycache__/run_suites*' -newer "$work/units.stamp" -print 2>/dev/null)" ] && ok \
  || fail "the units must not write tests/__pycache__ into the checkout"

# --- 10b. Paths a shell cannot stage on demand, driven in-process: a suite
# that ended just before the signal keeps its own verdict; a launch failure
# with a suite already running stops and reports it; a signal during startup
# ends the run before any suite; the grace period's both bounds; a signal
# mid-step starts nothing; the first signal names the exit; a main process
# that cannot be reaped after KILL is left behind, named, within the bound;
# an exception still stops the suites and removes the scratch root; a
# broken pipe during a launch is named as one.
# Each prints `ok NAME` or `BAD NAME: why`.
fresh
printf '#!/usr/bin/env bash\nexit 3\n' > "$s/e.sh"
printf '#!/usr/bin/env bash\necho SLOW-OUT\nsleep 300\n' > "$s/slow.sh"
printf '#!/usr/bin/env bash\n: > "$SHARED/ran"\n' > "$s/m.sh"
# e_wait.sh fails only once slowpid.sh has written its pid, the id of its group.
printf '#!/usr/bin/env bash\ni=0\nwhile [ ! -s "$SHARED/pid.txt" ] && [ "$i" -lt 300 ]; do i=$((i + 1)); sleep 0.1; done\nexit 3\n' > "$s/e_wait.sh"
printf '#!/usr/bin/env bash\necho "$$" > "$SHARED/pid.txt"\nsleep 300\n' > "$s/slowpid.sh"
printf '#!/usr/bin/env bash\ntrap "" TERM\n: > "$SHARED/deaf.sh.ready"\n%s\n' "$deaf_loop" > "$s/deaf.sh"
printf '#!/usr/bin/env bash\n: > "$SHARED/obey.sh.ready"\nsleep 300\n' > "$s/obey.sh"
cat > "$work/harness.py" <<'PY'
import errno, importlib.util, io, os, signal, sys, time
spec = importlib.util.spec_from_file_location("run_suites", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class Cap:
    def __init__(self):
        self.buffer = io.BytesIO()
    def flush(self):
        pass
    def text(self):
        return self.buffer.getvalue().decode()

def captured(fn):
    out, err = Cap(), Cap()
    real = sys.stdout, sys.stderr
    sys.stdout, sys.stderr = out, err
    try:
        rc = fn()
    finally:
        sys.stdout, sys.stderr = real
    return rc, out.text(), err.text()

def check(name, cond, why):
    print(("ok %s" % name) if cond else ("BAD %s: %s" % (name, why)))

def runner(paths, jobs, grace):
    r = m.Runner(paths, jobs, grace, m.Stop())
    assert r.setup() == 0
    return r

# 1. e.sh ends (exit 3) before the signal is acted on: FAILED, not INTERRUPTED.
r = runner(["e.sh", "slow.sh"], 2, 5.0)
def wait_exited(pid):
    # Exited, but not reaped: the runner still has to collect it.
    if not m.HAVE_WAITID:
        time.sleep(1.0)
        return
    for _ in range(3000):
        if os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None:
            return
        time.sleep(0.01)
def h1():
    r.launch(r.runs[0]); r.launch(r.runs[1])
    wait_exited(r.runs[0].proc.pid)
    r.stop.signum = signal.SIGTERM
    return r.interrupted()
rc, out, err = captured(h1)
m.remove_tree(r.root)
check("verdict kept", "done e.sh: FAILED (exit 3) in " in out, out)
check("other interrupted", "done slow.sh: INTERRUPTED (by SIGTERM) in " in out, out)
check("verdict rc", rc == 143, rc)

# 2. The second launch fails while the first suite runs: rc 1, the running
# suite stopped and reported, the scratch root removed.
real_popen = m.subprocess.Popen
calls = [0]
def popen(*a, **k):
    calls[0] += 1
    if calls[0] == 2:
        raise OSError("simulated launch failure")
    return real_popen(*a, **k)
m.subprocess.Popen = popen
os.environ["TEST_JOBS"] = "2"
rc, out, err = captured(lambda: m.main(["slow.sh", "m.sh"]))
m.subprocess.Popen = real_popen
check("launch rc", rc == 1, rc)
check("launch named", "could not start m.sh (simulated launch failure)" in err, err)
check("launch stops the running", "done slow.sh: INTERRUPTED (the run stopped: a suite could not start) in " in out, out)
check("launch cleans", os.listdir(os.environ["TMPDIR"]) == [], os.listdir(os.environ["TMPDIR"]))

# 3. A signal during startup (here: while the job count is read) ends the
# run with its own code before any suite starts, and leaves no root behind.
real_jc = m.job_count
def jc():
    os.kill(os.getpid(), signal.SIGTERM)
    time.sleep(0.2)
    return real_jc()
m.job_count = jc
rc, out, err = captured(lambda: m.main(["m.sh"]))
m.job_count = real_jc
for sig in m.EXIT_ON_SIGNAL:
    signal.signal(sig, signal.SIG_DFL)
check("startup rc", rc == 143, rc)
check("startup no suite", not os.path.exists(os.path.join(os.environ["SHARED"], "ran")), "m.sh ran")
check("startup no root", os.listdir(os.environ["TMPDIR"]) == [], os.listdir(os.environ["TMPDIR"]))

# 4. The grace period, on a clock that moves only when the runner sleeps, so
# the bounds are exact on any machine: a suite that ignores TERM gets KILL
# once the grace period is over, never later; one that obeys TERM ends the
# wait as soon as its group is empty, with no KILL at all, and keeps the
# status it was reaped with.
T0 = 1000.0
class Clock:
    def __init__(self):
        self.t = T0
    def monotonic(self):
        return self.t
    def sleep(self, s):
        self.t += s
        time.sleep(0.005)
real_time, real_kg, real_killpg = m.time, m.kill_group, m.os.killpg
def stopped_on_clock(path, grace, zombie_eperm=False):
    r = runner([path], 1, grace)
    r.launch(r.runs[0])
    ready = os.path.join(os.environ["SHARED"], path + ".ready")
    for _ in range(3000):
        if os.path.exists(ready):
            break
        time.sleep(0.01)
    clock, kills = Clock(), []
    def kg(pgid, sig):
        kills.append((sig, clock.t))
        real_kg(pgid, sig)
    def killpg(pgid, sig):
        # macOS answers a probe of a group whose only member left is a zombie
        # (a killed child that launchd has not reaped yet) with EPERM, not
        # ESRCH; Linux never does, so the hosted macOS leg alone hit it.
        if sig == 0:
            raise PermissionError(errno.EPERM, os.strerror(errno.EPERM))
        real_killpg(pgid, sig)
    m.time, m.kill_group = clock, kg
    if zombie_eperm:
        m.os.killpg = killpg
    try:
        captured(lambda: r.stop_all())
    finally:
        m.time, m.kill_group, m.os.killpg = real_time, real_kg, real_killpg
    m.remove_tree(r.root)
    return kills, r.runs[0]
kills, _ = stopped_on_clock("deaf.sh", 2.0)
at = [t for sig, t in kills if sig == signal.SIGKILL]
check("grace TERM first", kills and kills[0] == (signal.SIGTERM, T0), kills)
check("grace KILL at its end", len(at) == 1 and 2.0 <= at[0] - T0 <= 2.0 + m.POLL_SECONDS + 1e-6, kills)
kills, run = stopped_on_clock("obey.sh", 120.0)
check("grace no KILL for an obeyer", [s for s, _ in kills] == [signal.SIGTERM], kills)
# Reaped once, inside the wait: its status is the TERM that ended it.
check("grace obeyer status kept", run.code == -signal.SIGTERM, run.code)
# The same obeyer where its group's probe answers EPERM once bash is reaped,
# as macOS does while the killed `sleep` waits for launchd: nothing is left
# to stop, so no KILL and no wait to the grace's end. Read as live members,
# it failed the case above twice on the hosted macOS arm64 leg (runs
# 39488918611 and 39698323746): KILL at 1120.05 on this clock.
kills, run = stopped_on_clock("obey.sh", 120.0, zombie_eperm=True)
check("grace no KILL for a zombie-only group", [s for s, _ in kills] == [signal.SIGTERM], kills)
check("grace zombie-only status kept", run.code == -signal.SIGTERM, run.code)

# 5. A signal that lands while the scheduler reaps starts no new suite: the
# launch loop checks for it too, not only the top of the loop.
r = runner(["m.sh"], 1, 1.0)
def reap_signalled():
    r.stop.signum = signal.SIGTERM
    return []
r.reap = reap_signalled
rc, out, err = captured(r.schedule)
m.remove_tree(r.root)
check("mid-step rc", rc == 143, rc)
check("mid-step no launch", "start m.sh" not in out, out)

# 6. The first signal names the run's exit; a later one only counts.
st = m.Stop()
st.handler(signal.SIGINT, None)
st.handler(signal.SIGTERM, None)
check("first signal kept", (st.signum, st.count) == (signal.SIGINT, 2), (st.signum, st.count))

# 7. A main process that never becomes reapable: after KILL the reap gives
# up at the bound, names it, and the run goes on.
m.REAP_SECONDS = 0.3
r = runner(["slow.sh"], 1, 0.2)
r.launch(r.runs[0])
pid = r.runs[0].proc.pid
r.collect = lambda run: False
t0 = time.monotonic()
rc, out, err = captured(lambda: r.stop_all())
took = time.monotonic() - t0
os.waitpid(pid, 0)
m.remove_tree(r.root)
check("reap bound named", "slow.sh (pid %d) did not exit after KILL; left behind" % pid in err, err)
check("reap bound held", took < 5, took)
m.REAP_SECONDS = 5.0

# 8. An exception out of the scheduler (here: report() raising as e.sh's
# block is printed) still reaches the caller, after main()'s cleanup has
# stopped the running suite's group and removed the scratch root.
pidfile = os.path.join(os.environ["SHARED"], "pid.txt")
real_report = m.Runner.report
def report(self, run, verdict=None):
    raise RuntimeError("simulated report failure")
m.Runner.report = report
os.environ["TEST_JOBS"] = "2"
try:
    captured(lambda: m.main(["e_wait.sh", "slowpid.sh"]))
    raised = None
except RuntimeError as e:
    raised = e
m.Runner.report = real_report
for sig in m.EXIT_ON_SIGNAL:
    signal.signal(sig, signal.SIG_DFL)
check("exception propagates", raised is not None, "main() returned")
try:
    os.killpg(int(open(pidfile).read()), 0)
    gone = False
except ProcessLookupError:
    gone = True
except OSError:
    gone = False
check("exception stops the group", gone, "slowpid.sh's group is alive")
check("exception cleans", os.listdir(os.environ["TMPDIR"]) == [], os.listdir(os.environ["TMPDIR"]))

# 9. stdout closes just as a `start` line is written, the one write inside
# a launch: a broken pipe, never a suite that "could not start".
class Closed(Cap):
    def __init__(self):
        Cap.__init__(self)
        self.fd = os.open(os.devnull, os.O_WRONLY)
        real_write = self.buffer.write
        def write(b):
            if bytes(b).startswith(b"start "):
                raise BrokenPipeError(32, "Broken pipe")
            return real_write(b)
        self.buffer.write = write
    def fileno(self):
        return self.fd
out, err = Closed(), Cap()
real = sys.stdout, sys.stderr
sys.stdout, sys.stderr = out, err
try:
    rc = m.main(["m.sh"])
finally:
    sys.stdout, sys.stderr = real
for sig in m.EXIT_ON_SIGNAL:
    signal.signal(sig, signal.SIG_DFL)
check("broken pipe rc", rc == 1, rc)
check("broken pipe named", "stdout was closed (a broken pipe)" in err.text()
      and "could not start" not in err.text(), err.text())
check("broken pipe cleans", os.listdir(os.environ["TMPDIR"]) == [], os.listdir(os.environ["TMPDIR"]))
PY
bounded_run 60 "$work/harness" sh -c 'cd "$1" && shift && exec "$@"' sh "$s" \
  env TMPDIR="$tp" "$py" -I -B "$work/harness.py" "$runner"
harness="$(cat "$work/harness")"
[ "$br_hung" = 0 ] && [ "$br_stuck" = 0 ] || fail "the in-process harness hung: $harness"
grep -q '^BAD' <<<"$harness" && fail "in-process cases: $(grep '^BAD' <<<"$harness")" || ok
[ "$(grep -c '^ok' <<<"$harness")" = 27 ] && ok || fail "test bug: the in-process cases did not all run: $harness"

# --- 11. Verdicts, launch and input edge cases.
# A suite killed by a signal is a failure that names the signal.
fresh
suite k.sh 'echo K-OUT; kill -KILL $$'
run 1 k.sh
[ "$rc" = 1 ] && grep -q "^done k.sh: FAILED (killed by signal 9) in " <<<"$out" && ok \
  || fail "a suite killed by a signal must be reported as such (rc $rc): $out"
# A suite cannot start (no bash on PATH): named, exit 1, nothing left behind.
fresh
suite m.sh ': > "$SHARED/ran"'
mkdir -p "$work/nobash"
extra_env=(PATH="$work/nobash")
run 1 m.sh
extra_env=()
[ "$rc" = 1 ] && grep -q "^ERROR: test: could not start m.sh" <<<"$err" && ok \
  || fail "a suite that cannot start must fail the run, named (rc $rc): $out $err"
empty_tp && ok || fail "a failed start must leave no scratch root: $(ls -A "$tp")"
# A suite's stdin is /dev/null, whatever the runner's is; and one lone suite
# is counted in the singular.
fresh
suite in.sh 'if IFS= read -r l; then echo "STDIN: $l"; exit 4; fi'
printf 'LEAKED\n' > "$work/stdin"
RUN_STDIN="$work/stdin" run 8 in.sh
[ "$rc" = 0 ] && ok || fail "a suite must read its stdin from /dev/null (rc $rc): $out"
grep -qx "test: 1 suite (0 serial), 1 at a time (TEST_JOBS=8)" <<<"$out" && ok \
  || fail "one suite must be counted in the singular, and run 1 at a time: $out"
[ "$(tail -n 1 <<<"$out")" = "test: 1 test file passed" ] && ok \
  || fail "one passing suite must end with 'test: 1 test file passed': $out"
# A suite named like an option is still a file: bash gets `--` first.
fresh
suite -n.sh 'echo DASH-RAN'
run 1 -n.sh
[ "$rc" = 0 ] && grep -qx "DASH-RAN" <<<"$out" && ok || fail "a suite named -n.sh must run as a file (rc $rc): $out $err"
# A suite's block is read back from the log it wrote, through the runner's
# own descriptor: a suite that replaces its log file (logs/ sits two levels
# above its TMPDIR) cannot make the runner print another file.
fresh
suite swap.sh 'echo REAL-OUT
log="$TMPDIR/../../logs/1.log"
[ -f "$log" ] || { echo "test bug: no log at $log"; exit 9; }
rm -f "$log" && echo FORGED > "$log"'
run 1 swap.sh
[ "$rc" = 0 ] && grep -qx REAL-OUT <<<"$out" && ! grep -q FORGED <<<"$out" && ok \
  || fail "a suite that swaps its log file must still get its own output printed (rc $rc): $out"
# A suite cannot make the runner write through a later suite's log path: a
# symlink planted there is never followed. The runner fails closed, as for a
# suite that could not start: the later suite never runs, the run exits 1 and
# names it, and the file the symlink names keeps its content.
fresh
printf 'ORIG\n' > "$SHARED/outside"
suite plant.sh 'ln -s "$SHARED/outside" "$TMPDIR/../../logs/2.log"'
suite victim.sh 'echo VICTIM-OUT; : > "$SHARED/victim.ran"'
run 1 plant.sh victim.sh
[ "$rc" = 1 ] && grep -q "^ERROR: test: could not start victim.sh (.*File exists" <<<"$err" && ok \
  || fail "a symlink planted at a later suite's log path must fail the run, naming that suite (rc $rc): $out $err"
[ "$(cat "$SHARED/outside")" = ORIG ] && ok \
  || fail "the runner must not write through a planted log symlink: outside now holds $(cat "$SHARED/outside")"
[ ! -e "$SHARED/victim.ran" ] && ok || fail "a suite whose log path was planted must not run"
empty_tp && ok || fail "a planted log symlink must still leave no scratch root: $(ls -A "$tp")"
# What a suite leaves running in its process group dies with it.
fresh
suite leave.sh 'sleep 300 &
echo "$!" > "$SHARED/left.pid"'
run 1 leave.sh
[ "$rc" = 0 ] && ok || fail "a suite leaving a background process must still pass (rc $rc): $out"
left="$(cat "$SHARED/left.pid")"
gone "$left" 10 && ok || { kill -KILL "$left" 2>/dev/null || true; fail "a process left in an ended suite's group must be killed (pid $left)"; }
# The peak RSS is measured, not only printed: a suite whose child touches
# 64 MiB reports at least 60 MiB (ru_maxrss is KiB on Linux, bytes on macOS;
# the runner converts both).
fresh
suite big.sh '"$PY" -I -c "b = b\"x\" * (64 << 20); print(len(b))"'
extra_env=(PY="$py")
run 1 big.sh
extra_env=()
peak="$(sed -n 's/^done big\.sh: ok in [0-9.]*s, peak RSS \([0-9]*\) MiB$/\1/p' <<<"$out")"
[ "$rc" = 0 ] && [ -n "$peak" ] && [ "$peak" -ge 60 ] && ok \
  || fail "a suite that touches 64 MiB must report a peak RSS of at least 60 MiB (rc $rc, peak '$peak'): $out"
# A suite that leaves a read-only directory holding a symlink to a directory
# outside the scratch root: the root is still removed, and the outside
# directory's mode is left alone (the fallback makes directories writable
# without following links). Root ignores permissions, so the first removal
# would never fail and the fallback never run: the case needs another user.
if [ "$(id -u)" != 0 ]; then
  fresh
  mkdir -p "$SHARED/outside"
  chmod 555 "$SHARED/outside"
  suite ro.sh 'mkdir "$TMPDIR/ro" && ln -s "$SHARED/outside" "$TMPDIR/ro/link" && chmod 500 "$TMPDIR/ro"'
  run 1 ro.sh
  mode="$("$py" -I -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$SHARED/outside")"
  chmod 755 "$SHARED/outside"
  [ "$rc" = 0 ] && empty_tp && ok || fail "a read-only directory left by a suite must not keep the scratch root (rc $rc): $(ls -A "$tp") $err"
  [ "$mode" = 0o555 ] && ok || fail "removing the scratch root must not follow a link out of it (outside dir now $mode)"
else
  echo "SKIP: running as root, which ignores permissions - the read-only scratch root case was not run"
fi
# A closed stdout (its reader, such as `head`, went away) is a broken pipe,
# reported as one: the run stops its suites, removes the scratch root and
# exits 1. It is never a suite that "could not start". The reader here closes
# the pipe once p1.sh runs and only then writes the `gone` marker, which p2.sh
# waits for, so p2.sh's block is the first write to fail, however loaded the
# host: a write that beat the reader's exit would leave the runner waiting on
# p1.sh until the 60s bound. The second shape sends stderr to the same reader
# (`make test 2>&1 | head`): the message is lost with it, and the exit must
# still be 1, never the 120 of a Python that cannot flush stderr at exit.
bp_suites() {
  fresh
  suite p1.sh 'echo "$$" > "$SHARED/p1.pid"; sleep 300'
  suite p2.sh 'i=0; while [ ! -s "$SHARED/gone" ]; do i=$((i + 1)); [ "$i" -le 300 ] || exit 9; sleep 0.1; done; echo P2'
}
bp_reader='{ IFS= read -r _ || :; while [ ! -s "$SHARED/p1.pid" ]; do sleep 0.1; done; exec 0<&-; echo gone > "$SHARED/gone"; }'
bp_check() {
  [ "$br_hung" = 0 ] && [ "$br_stuck" = 0 ] || fail "a runner with a closed stdout must not hang ($1): $err"
  empty_tp && ok || fail "a closed stdout must still remove the scratch root ($1): $(ls -A "$tp")"
  p1="$(cat "$SHARED/p1.pid")"
  gone "$p1" 10 && ok || { kill -KILL "$p1" 2>/dev/null || true; fail "a closed stdout must stop the running suites ($1, pid $p1 alive)"; }
}
bp_suites
bounded_run 60 "$work/bp" bash -c 'cd "$1" && shift && "$@" 2>"$0" \
  | '"$bp_reader"'; exit "${PIPESTATUS[0]}"' \
  "$work/err" "$s" env TEST_JOBS=2 TMPDIR="$tp" "$py" -I "$runner" p1.sh p2.sh
err="$(cat "$work/err")"
bp_check "stdout only"
[ "$br_rc" = 1 ] && grep -q "^ERROR: test: stdout was closed (a broken pipe)" <<<"$err" && ok \
  || fail "a closed stdout must be reported as a broken pipe, exit 1 (rc $br_rc): $err"
grep -q "could not start" <<<"$err" && fail "a closed stdout is not a suite that could not start: $err" || ok
bp_suites
bounded_run 60 "$work/bp" bash -c 'cd "$0" && "$@" 2>&1 \
  | '"$bp_reader"'; exit "${PIPESTATUS[0]}"' \
  "$s" env TEST_JOBS=2 TMPDIR="$tp" "$py" -I "$runner" p1.sh p2.sh
err="$(cat "$work/bp")"
bp_check "stdout and stderr"
[ "$br_rc" = 1 ] && ok || fail "a closed stdout and stderr must still exit 1 (rc $br_rc): $err"
# A suite path that is not UTF-8 is printed as its bytes, never a traceback.
# macOS file systems refuse such names, so the case runs where they exist.
# The braces carry the 2>/dev/null: a failing redirection reports its error
# (`Illegal byte sequence` on macOS) before a 2>/dev/null after it applies.
fresh
badname="$(printf 'bad\377.sh')"
if { printf 'echo BAD-RAN; exit 1\n' > "$s/$badname"; } 2>/dev/null; then
  run 1 "$badname"
  [ "$rc" = 1 ] && ok || fail "a failing suite with a non-UTF-8 name must exit 1 (rc $rc): $err"
  grep -q Traceback <<<"$err$out" && fail "a non-UTF-8 suite name must not raise: $err" || ok
  LC_ALL=C grep -q "^test: FAILED: bad.\\.sh\$" "$work/err" && ok \
    || fail "a non-UTF-8 suite must be named by its bytes: $err"
else
  echo "SKIP: this file system refuses a non-UTF-8 file name - that case was not run"
fi

# --- 12. The recipe: `make test` execs the runner (a signal must reach it,
# not a shell waiting on it); it fails closed without python3, before any
# suite runs, whatever STRICT says; and a hostile TEST_JOBS on make's command
# line reaches the runner as data, never as shell text.
recipe="$(awk 'index($0, "test:") == 1 { p = 1; next } p && !/^\t/ { p = 0 } p' "$repo_root/Makefile")"
grep -qE "^[[:space:]]*exec python3 -I '[^']*tests/run_suites\.py' \\\$\(TEST_FILES\)\$" <<<"$recipe" && ok \
  || fail "the Makefile test recipe must exec the runner: $recipe"
if make_bin="$(command -v make)"; then
  fresh
  suite m.sh ': > "$SHARED/ran"'
  nopy="$work/nopy"; mkdir -p "$nopy"
  for tool in git grep; do ln -s "$(command -v "$tool")" "$nopy/$tool"; done
  bounded_run 60 "$work/out" sh -c 'cd "$1" && shift && exec "$@"' sh "$s" \
    env -u STRICT -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEFILES PATH="$nopy" \
    "$make_bin" -f "$repo_root/Makefile" test TEST_FILES=m.sh
  [ "$br_hung" = 0 ] && [ "$br_rc" != 0 ] && ok || fail "make test without python3 must fail: $(cat "$work/out")"
  grep -q "ERROR: make test needs python3" "$work/out" && ok || fail "make test must say python3 is missing: $(cat "$work/out")"
  [ ! -e "$SHARED/ran" ] && ok || fail "no suite may run without python3"
  fresh
  suite m.sh ': > "$SHARED/ran"'
  hostile="1\"; : > $SHARED/spliced; \""
  bounded_run 60 "$work/out" sh -c 'cd "$1" && shift && exec "$@"' sh "$s" \
    env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEFILES \
    "$make_bin" -f "$repo_root/Makefile" test TEST_FILES=m.sh "TEST_JOBS=$hostile"
  [ "$br_hung" = 0 ] && [ "$br_rc" != 0 ] && ok || fail "a hostile TEST_JOBS must fail the run: $(cat "$work/out")"
  [ ! -e "$SHARED/spliced" ] && [ ! -e "$SHARED/ran" ] && ok \
    || fail "a hostile TEST_JOBS must reach the runner as data, before any suite: $(cat "$work/out")"
  grep -q "TEST_JOBS must be a positive integer" "$work/out" && ok || fail "the runner must refuse the hostile TEST_JOBS: $(cat "$work/out")"
else
  [ -z "${STRICT:-}" ] || fail "make not found and STRICT=1 - the recipe cases cannot be tested"
  echo "SKIP: make not found - the recipe cases were not tested"
fi

echo "PASS: run_suites_test ($pass assertions)"
