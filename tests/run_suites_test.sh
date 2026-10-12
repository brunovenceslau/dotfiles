#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Tests for tests/run_suites.py, the runner `make test` execs: suites run
# several at a time, each under its own TMPDIR behind a symlink, with output
# buffered per suite, every failure named, serial suites alone, and the
# scratch root removed on every exit path, a signal included. Each case runs
# the real runner over fixture suites written into a scratch directory, under
# a TMPDIR of its own, so "nothing left behind" is a plain `ls -A`.
# Concurrency is proven with barriers (each suite waits until all of them have
# started), never with timings, so a slow machine cannot turn a case red.
# tests/make_test_env_scrub_test.sh holds the recipe's side: the git env scrub,
# TMPDIR made absolute, the 129/130/143 exits as make reports them.
set -euo pipefail
set -E
trap '_err_rc=$?; [ "${BASH_SUBSHELL:-0}" -ne 0 ] || echo "ERR: unexpected failure at line $LINENO (rc $_err_rc): $BASH_COMMAND" >&2' ERR

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runner="$repo_root/tests/run_suites.py"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); }

if ! command -v python3 >/dev/null 2>&1; then
  [ -z "${STRICT:-}" ] || fail "python3 not found and STRICT=1 - the runner cannot be tested"
  echo "SKIP: run_suites_test (python3 not found)"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/run_suites_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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
# run JOBS SUITE... - the runner from $s with TEST_JOBS=JOBS and TMPDIR=$tp;
# stdout in $out, stderr in $err, exit code in $rc.
run() {
  local jobs="$1"
  shift
  rc=0
  (cd "$s" && TEST_JOBS="$jobs" TMPDIR="$tp" python3 -I "$runner" "$@") \
    > "$work/out" 2> "$work/err" || rc=$?
  out="$(cat "$work/out")"; err="$(cat "$work/err")"
}
empty_tp() { [ -z "$(ls -A "$tp")" ]; }
# A barrier: the suite marks itself started and waits, up to 30s, until N
# suites have. It passes only when N of them were running at the same time.
barrier() {
  printf ': > "$SHARED/started.%s"\ni=0\nwhile [ "$(ls "$SHARED" | grep -c "^started\\.")" -lt %s ]; do\n  i=$((i + 1)); [ "$i" -le 300 ] || { echo "BARRIER TIMEOUT"; exit 9; }\n  sleep 0.1\ndone\n' "$1" "$2"
}

# --- 1. Several at a time: three suites pass a three-way barrier, so all ran
# at once; every block is opened by `run` and closed by `done`; the times are
# listed slowest first; the last line is the one `make test` always printed.
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
# list order, a passing suite between them does not hide one, exit is 1.
fresh
suite a_fail.sh 'echo A; exit 1'
suite b_ok.sh 'echo B'
suite c_fail.sh 'echo C; exit 3'
run 1 a_fail.sh b_ok.sh c_fail.sh
[ "$rc" = 1 ] && ok || fail "a failing suite must make the runner exit 1 (rc $rc): $out $err"
grep -qx "test: FAILED: a_fail.sh c_fail.sh" <<<"$err" && ok \
  || fail "stderr must name every failed suite, in list order: $err"
grep -qx "done c_fail.sh: FAILED (exit 3) in [0-9.]*s, peak RSS [0-9]* MiB" <<<"$out" && ok \
  || fail "a suite after a failure must still run and report its own exit code: $out"
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

# --- 6. A signal stops every running suite, its own children included, and
# removes the scratch root; the runner exits 128+N.
for sig in HUP:129 INT:130 TERM:143; do
  code="${sig#*:}"; sig="${sig%:*}"
  fresh
  suite slow.sh 'sleep 300 &
echo "$!" > "$SHARED/child.pid"
wait'
  suite other.sh 'sleep 300'
  (cd "$s" && TEST_JOBS=2 TMPDIR="$tp" exec python3 -I "$runner" slow.sh other.sh) \
    > "$work/out" 2>&1 &
  rpid=$!
  i=0
  while [ ! -s "$SHARED/child.pid" ]; do
    i=$((i + 1)); [ "$i" -le 300 ] || { kill -KILL "$rpid" 2>/dev/null || true; fail "test bug: slow.sh never started ($sig)"; }
    sleep 0.1
  done
  kill -"$sig" "$rpid"
  rc=0; wait "$rpid" || rc=$?
  [ "$rc" = "$code" ] && ok || fail "$sig must make the runner exit $code, got $rc: $(cat "$work/out")"
  grep -q "test: interrupted by SIG$sig" "$work/out" && ok || fail "the runner must say it was interrupted by $sig: $(cat "$work/out")"
  empty_tp && ok || fail "$sig must leave no scratch root behind: $(ls -A "$tp")"
  child="$(cat "$SHARED/child.pid")"
  i=0
  while kill -0 "$child" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -le 100 ] || { kill -KILL "$child" 2>/dev/null || true; fail "$sig must stop a suite's own children too (pid $child alive)"; }
    sleep 0.1
  done
  ok
done

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
# The marker must be the whole line: a mention of it does not make a suite serial.
fresh
suite s1.sh "$(barrier s1 2)
echo 'not a marker: # run_suites: serial'"
suite s2.sh "$(barrier s2 2)"
run 2 s1.sh s2.sh
[ "$rc" = 0 ] && ok || fail "a suite only mentioning the marker must stay in the pool (rc $rc): $out"

# --- 8. No suites: the message `make test` always printed, exit 0, nothing made.
fresh
run 1
[ "$rc" = 0 ] && [ "$out" = "test: no tests found" ] && ok \
  || fail "an empty list must print 'test: no tests found' and exit 0 (rc $rc): $out"
empty_tp && ok || fail "an empty list must make no scratch root: $(ls -A "$tp")"

# --- 9. Fail closed: a bad TEST_JOBS or an unusable TMPDIR stops the run
# before any suite starts.
for bad in 0 abc -1 "2 " 1.5 10000; do
  fresh
  suite m.sh ': > "$SHARED/ran"'
  run "$bad" m.sh
  [ "$rc" = 1 ] && ok || fail "TEST_JOBS='$bad' must fail closed (rc $rc): $out $err"
  grep -q "^ERROR: test: TEST_JOBS must be a positive integer" <<<"$err" && ok \
    || fail "TEST_JOBS='$bad' must say why: $err"
  [ ! -e "$SHARED/ran" ] && ok || fail "no suite may run with TEST_JOBS='$bad'"
done
fresh
suite m.sh ': > "$SHARED/ran"'
rc=0
(cd "$s" && TEST_JOBS=1 TMPDIR="$work/missing" python3 -I "$runner" m.sh) > "$work/out" 2> "$work/err" || rc=$?
[ "$rc" = 1 ] && ok || fail "a missing TMPDIR must fail closed (rc $rc): $(cat "$work/out" "$work/err")"
grep -q "^ERROR: test: could not make the scratch root" "$work/err" && ok \
  || fail "a missing TMPDIR must be named as the reason: $(cat "$work/err")"
[ ! -e "$SHARED/ran" ] && ok || fail "no suite may run without a scratch root"

# --- 10. The default job count: min(CPUs, available memory / the per-suite
# budget), at least 1, and the macOS vm_stat reading. Pure functions, so the
# arithmetic is checked here on every platform.
units="$(python3 -I - "$runner" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("run_suites", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
mib = 1024 * 1024
b = m.SUITE_MEMORY_MIB * mib
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
]
for name, got, want in checks:
    print("%s %s: got %r, want %r" % ("ok" if got == want else "BAD", name, got, want))
PY
)"
grep -q '^BAD' <<<"$units" && fail "job count units: $(grep '^BAD' <<<"$units")" || ok
[ "$(grep -c '^ok' <<<"$units")" = 7 ] && ok || fail "test bug: the job count units did not all run: $units"

# --- 11. `make test` without python3 fails closed, before any suite runs,
# whatever STRICT says: a run that tests nothing must never look green.
if make_bin="$(command -v make)"; then
  fresh
  suite m.sh ': > "$SHARED/ran"'
  nopy="$work/nopy"; mkdir -p "$nopy"
  for tool in git grep; do ln -s "$(command -v "$tool")" "$nopy/$tool"; done
  rc=0
  (cd "$s" && env -u STRICT -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEFILES PATH="$nopy" \
    "$make_bin" -f "$repo_root/Makefile" test TEST_FILES=m.sh) > "$work/out" 2>&1 || rc=$?
  [ "$rc" != 0 ] && ok || fail "make test without python3 must fail: $(cat "$work/out")"
  grep -q "ERROR: make test needs python3" "$work/out" && ok || fail "make test must say python3 is missing: $(cat "$work/out")"
  [ ! -e "$SHARED/ran" ] && ok || fail "no suite may run without python3"
else
  [ -z "${STRICT:-}" ] || fail "make not found and STRICT=1 - the recipe's python3 guard cannot be tested"
  echo "SKIP: make not found - the recipe's python3 guard was not tested"
fi

echo "PASS: run_suites_test ($pass assertions)"
