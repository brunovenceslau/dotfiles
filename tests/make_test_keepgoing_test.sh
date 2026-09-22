#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit test for the Makefile `test` target's KEEP-GOING behavior (
# make-test-early-abort-masks-cascade). The old recipe `bash "$$t" || exit 1` ABORTED at the
# first failing test, MASKING a multi-bug cascade (packages_test bash-3.2 parse -> verify_test
# stale-hash surfaced one-per-CI-round). The recipe now runs EVERY test, reports ALL failures,
# and exits nonzero iff any failed. `make` may be absent, so this replicates the
# recipe LOOP over fixture test files and proves: both failures are reported (not just the
# first) and the overall rc is nonzero - and, by contrast, that the old early-abort shape
# reports only the first (the regression this closes). Not on the shellcheck surface.
set -euo pipefail

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { pass=$((pass + 1)); }
work="$(mktemp -d "${TMPDIR:-/tmp}/make_test_keepgoing.XXXXXX")"; trap 'rm -rf "$work"' EXIT

# three fixture "tests": two FAIL, one passes, ordered so a failure is NOT last.
mkdir -p "$work/t"
printf '#!/usr/bin/env bash\necho A; exit 1\n' > "$work/t/a_fail.sh"
printf '#!/usr/bin/env bash\necho B; exit 0\n' > "$work/t/b_ok.sh"
printf '#!/usr/bin/env bash\necho C; exit 1\n' > "$work/t/c_fail.sh"
files="$work/t/a_fail.sh $work/t/b_ok.sh $work/t/c_fail.sh"

# the KEEP-GOING recipe body (mirrors the Makefile `test:` recipe, with $$ -> $).
keepgoing() {
  local failed="" t
  for t in $files; do echo "run $t"; bash "$t" || failed="$failed $t"; done
  if [ -n "$failed" ]; then echo "test: FAILED:$failed" >&2; return 1; fi
  echo "test: all passed"   # the success-branch summary - mirrors the Makefile recipe's echo
}
out="$(keepgoing 2>&1)" && krc=0 || krc=$?

# 1) overall rc is nonzero - a failure is still a failure.
[ "$krc" -ne 0 ] && ok || fail "keep-going must exit nonzero when a test fails (got rc=$krc)"
# 2) BOTH failing files are reported - the whole point (early-abort masked the second).
if printf '%s\n' "$out" | grep -q 'a_fail.sh' && printf '%s\n' "$out" | grep -q 'c_fail.sh'; then ok
else fail "keep-going must report BOTH failing files, not stop at the first: $out"; fi
# 3) it kept RUNNING past the first failure (the `run …c_fail.sh` line appears).
printf '%s\n' "$out" | grep -q '^run .*c_fail.sh' && ok \
  || fail "keep-going must run every test file even after an earlier failure: $out"

# RED contrast: the OLD early-abort variant (`|| return 1`) reports ONLY the first failure -
# the regression this closes. Assert it does NOT reach c_fail.sh (it aborts at a_fail.sh).
earlyabort() { local t; for t in $files; do echo "run $t"; bash "$t" || return 1; done; }
oout="$(earlyabort 2>&1)" || true
printf '%s\n' "$oout" | grep -q 'c_fail.sh' \
  && fail "test bug: early-abort should abort at a_fail.sh and never reach c_fail.sh: $oout" \
  || ok

# 5) the ALL-PASS path: every test passes -> rc 0 AND the success-branch summary prints. This
# branch (previously untested) is what proves the change didn't turn a clean run into a failure.
printf '#!/usr/bin/env bash\necho D; exit 0\n' > "$work/t/d_ok.sh"
files="$work/t/b_ok.sh $work/t/d_ok.sh"
pout="$(keepgoing 2>&1)" && prc=0 || prc=$?
{ [ "$prc" -eq 0 ] && printf '%s\n' "$pout" | grep -q 'test: all passed'; } && ok \
  || fail "keep-going all-pass path must exit 0 and print the summary (got rc=$prc): $pout"

echo "PASS: make_test_keepgoing_test ($pass assertions)"
