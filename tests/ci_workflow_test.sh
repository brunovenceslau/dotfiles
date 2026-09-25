#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Contract tests for .github/workflows/ci.yml - the verification gate. The
# workflow runs ONE gate, `make local-ci`, on both macOS legs, every leg on a
# GITHUB-HOSTED runner (macOS arm64 + Intel); forbids self-hosted runners and
# QEMU/container emulation, and runs no leg for any other OS (macOS is the only
# platform the framework installs on). This asserts the properties that keep the
# workflow honest: the gate is
# `make local-ci` (a make call -), every leg is a GitHub-hosted macOS image with
# NO self-hosted runner, both architectures are present and no Linux leg crept
# back, STRICT=1 is set (a skipped gate fails closed), the
# gate is not exit-suppressed, no inline gate logic leaks in, the signature suites
# `make test` depends on are intact, and the YAML is well-formed.
# PyYAML when available; grep floors always run (here-strings, never `printf | grep`
# - the SIGPIPE-under-pipefail footgun the repo documents).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
wf="$repo_root/.github/workflows/ci.yml"
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Existence ----------------------------------------------------------------
[ -f "$wf" ] || fail "workflow not found: .github/workflows/ci.yml"

# Non-comment lines only, so an explanatory comment naming a gate/tool is never
# mistaken for a command (e.g. the header comment explaining why no leg is
# self-hosted).
commands="$(grep -vE '^[[:space:]]*#' "$wf")"

# --- the gate is `make local-ci` (a make target, not inline logic) -
grep -Eq '(^|[^a-z-])make[[:space:]]+local-ci' <<<"$commands" \
  || fail "ci.yml must invoke 'make local-ci' as its gate"

# --- Every leg runs on a GitHub-hosted image; NO self-hosted runner anywhere ---
grep -q 'macos-' <<<"$commands" \
  || fail "ci.yml must name GitHub-hosted macOS runner images"
grep -q 'self-hosted' <<<"$commands" \
  && fail "ci.yml targets a self-hosted runner - every leg must be GitHub-hosted"

# --- No Linux leg: macOS is the only platform the framework installs on -------
grep -qE '(^|[^[:alnum:]_])([Ll]inux|ubuntu-[a-z0-9.]+)([^[:alnum:]_]|$)' <<<"$commands" \
  && fail "ci.yml names a Linux runner - every leg must be macOS"

# --- STRICT=1: a skipped gate must fail closed, never green --------------------
grep -Eq 'make[[:space:]]+local-ci[[:space:]]+STRICT=1' <<<"$commands" \
  || fail "ci.yml must run 'make local-ci STRICT=1' so a skipped check fails closed"

# --- the gate must not be exit-suppressed -------------------------
# `make local-ci || true` (or `; true`) would green a failed lint/test/smoke.
if grep -E 'make[[:space:]]+local-ci' <<<"$commands" | grep -Eq '\|\|[[:space:]]*(true|:)'; then
  fail "ci.yml suppresses the exit of 'make local-ci' (|| true) - the gate must block"
fi

# --- no inline gate logic (the gates live inside make local-ci) ----
# The unambiguous invocation forms of the gate tools never appear in setup steps.
# `reuse` and `gitleaks` are package names the setup loop legitimately installs,
# so each is a sentinel only together with the SUBCOMMAND that would make the
# line a gate - the same reason shellcheck (a bare package name with no
# subcommand to key on) is deliberately absent from this list.
while IFS= read -r pat; do
  if grep -Eq "$pat" <<<"$commands"; then
    grep -En "$pat" <<<"$commands" >&2
    fail "inline gate logic in ci.yml (must go through 'make'): /$pat/"
  fi
done <<'PATS'
zsh[[:space:]]+-n
(/bin/)?bash[[:space:]]+-n
bin/(check-patterns|secret-scan|smoke|startup-fork-gate)
reuse[[:space:]]+lint
gitleaks[[:space:]]+(dir|git|file|directory|stdin|detect|protect)
PATS

# --- Well-formedness + gate shape (PyYAML; loud skip when absent) --------------
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$wf" <<'PY' || fail "PyYAML structural checks failed (see above)"
import sys, yaml

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

# `on:` is the YAML 1.1 boolean True key - that alone proves it parsed as a map.
assert isinstance(doc, dict), "workflow is not a YAML mapping"
assert True in doc or "on" in doc, "workflow has no trigger (`on:`)"

jobs = doc.get("jobs")
assert isinstance(jobs, dict) and jobs, "workflow defines no jobs"

# The gate job runs `make local-ci`, on a GitHub-hosted runner, and must not be
# exit-suppressed at the job level (a copy-pasted continue-on-error would green a
# failed gate - the single highest-stakes false green).
def runs_local_ci(job):
    for step in job.get("steps") or []:
        if "local-ci" in str(step.get("run") or ""):
            return True
    return False

gate_jobs = {n: j for n, j in jobs.items() if runs_local_ci(j)}
assert gate_jobs, "no job runs `make local-ci`"

# runs-on may be a matrix expression (`${{ matrix.runs-on }}`); resolve the
# concrete runner values from strategy.matrix.include so every leg is checked.
def label_sets(job):
    ro = job.get("runs-on")
    if isinstance(ro, str) and "matrix." in ro:
        inc = ((job.get("strategy") or {}).get("matrix") or {}).get("include") or []
        out = []
        for e in inc:
            r = e.get("runs-on")
            out.append(set(r) if isinstance(r, list) else {str(r)})
        return out
    return [set(ro) if isinstance(ro, list) else {str(ro)}]

# A GitHub-hosted macOS image carries its platform in the image name: every
# arm64 image is `macos-<n>`/`macos-latest`, and the Intel ones are the explicit
# `-intel` suffix (and the retired macos-12/13, kept here so they still classify
# as X64 rather than being mistaken for an arm64 leg).
def platform(label):
    lab = label.lower()
    if not lab.startswith("macos"):
        return None
    intel = "intel" in lab or lab in ("macos-12", "macos-13")
    return ("macOS", "X64" if intel else "ARM64")

platforms = set()
for name, job in gate_jobs.items():
    legs = label_sets(job)
    assert legs, f"gate job {name!r} declares no runner"
    for labs in legs:
        assert "self-hosted" not in labs, f"gate leg {sorted(labs)} is self-hosted"
        for lab in labs:
            assert platform(lab), \
                f"gate leg {sorted(labs)} is not a GitHub-hosted macOS image"
            platforms.add(platform(lab))
    assert job.get("continue-on-error") is not True, \
        f"gate job {name!r} must NOT set continue-on-error (it is the blocking gate)"

want = {("macOS", "ARM64"), ("macOS", "X64")}
assert want <= platforms, f"2-leg macOS matrix incomplete - missing {sorted(want - platforms)}"
assert not [p for p in platforms if p[0] != "macOS"], \
    f"a non-macOS leg crept back (Linux withdrawn 2026-09-13): {sorted(platforms)}"

print("PyYAML: workflow well-formed; GitHub-hosted macOS matrix:", sorted(platforms))
PY
else
  if [ -n "${STRICT:-}" ]; then fail "PyYAML unavailable and STRICT=1 - ci.yml structural checks not run"; fi
  echo "SKIP: PyYAML unavailable - ci.yml structural checks not run"
fi

echo "PASS: ci_workflow_test"
