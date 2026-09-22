#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Tests for the `make gitleaks` secret-scanning gate. gitleaks ships and
# maintains its own rule set, so what can rot here is the WIRING and the one
# piece of configuration this repository actually writes - the allowlist - and
# both rot silently: a gate that is not a local-ci prerequisite runs nowhere, a
# gate that skips instead of failing under STRICT=1 reports green on a check
# that never executed, and an allowlist with a typo either waives everything or
# waives nothing. The wiring is asserted statically, so it is caught without the
# tool installed; the allowlist is asserted by running the real binary over a
# hermetic fixture, in BOTH directions.
#
# Needles here are assembled from fragments at run time, for the reason
# tests/secret_scan_test.sh states at length: no secret-shaped literal belongs
# in the tracked tree, marker or no marker.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mk="$repo_root/Makefile"
wf="$repo_root/.github/workflows/ci.yml"
cfg="$repo_root/.gitleaks.toml"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ok: $1"; }

# --- Wiring: the target exists and runs the scanner ---------------------------
grep -Eq '^gitleaks:' "$mk" || fail "Makefile has no 'gitleaks' target"
grep -q 'gitleaks dir' "$mk" || fail "Makefile 'gitleaks' target must run 'gitleaks dir'"
ok "Makefile defines a 'gitleaks' target that runs 'gitleaks dir'"

# --- Wiring: gitleaks is a local-ci prerequisite ------------------------------
# A blocking gate MUST be reachable from local-ci, or `make local-ci` before a
# push proves nothing about it. Same assertion shape as the reuse gate's.
# grep -w is supported by GNU and macOS BSD grep.
if ! grep -E '^local-ci:' "$mk" | grep -qw gitleaks; then
  fail "gitleaks must be a local-ci prerequisite (it is a blocking gate)"
fi
ok "gitleaks is a local-ci prerequisite"

# --- Wiring: STRICT=1 fails closed --------------------------------------------
# Two separate greps rather than one combined pattern, so the failure message
# says which half is missing.
recipe="$(awk '/^gitleaks:/{p=1; next} /^[^\t]/{p=0} p' "$mk")"
[ -n "$recipe" ] || fail "could not read the 'gitleaks' target's recipe out of the Makefile"
grep -q 'STRICT' <<<"$recipe" \
  || fail "the 'gitleaks' recipe ignores STRICT - a missing tool would skip even in CI"
grep -q 'exit 1' <<<"$recipe" \
  || fail "the 'gitleaks' recipe must exit 1 under STRICT=1 when gitleaks is absent"
ok "the 'gitleaks' recipe fails closed under STRICT=1"

# --- Wiring: CI provisions the tool -------------------------------------------
# local-ci runs under STRICT=1 in CI, so a gate CI cannot install is a red leg.
# The gate-tools loop is the single place that decides what CI provisions;
# tests/dev_docs_prereqs_test.sh then holds the docs to that same list.
grep -E '^\s*for tool in .*; do\s*$' "$wf" | grep -qw gitleaks \
  || fail "ci.yml's gate-tools loop does not install gitleaks, which local-ci STRICT=1 requires"
ok "ci.yml's gate-tools loop installs gitleaks"

# --- Config: the maintained rule set, plus the one shared waiver token --------
[ -f "$cfg" ] || fail "no .gitleaks.toml - the gate would fall back to an unpinned default"
grep -Eq '^\s*useDefault\s*=\s*true' "$cfg" \
  || fail ".gitleaks.toml must set [extend] useDefault = true (the maintained rule set)"
grep -Eq '^\s*regexTarget\s*=\s*"line"' "$cfg" \
  || fail ".gitleaks.toml's allowlist must use regexTarget = \"line\" so a marker beside the secret counts"
grep -q 'secret-scan:allow' "$cfg" \
  || fail ".gitleaks.toml must allowlist the same 'secret-scan:allow' token bin/secret-scan honours"
ok ".gitleaks.toml extends the default rule set and shares bin/secret-scan's waiver token"

# --- Behaviour: the allowlist works in BOTH directions ------------------------
# A config that waived everything would pass every assertion above, and a
# scanner that flagged nothing would pass the second half of this one. So the
# same needle is scanned twice, and the ONLY difference between the two files is
# the marker: without it the scan must fail, with it the scan must pass.
if command -v gitleaks >/dev/null 2>&1; then
  work="$(mktemp -d "${TMPDIR:-/tmp}/gitleaks_gate_test.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  pem_begin='-----BEGIN OPENSSH PRIV''ATE KEY-----'
  pem_end='-----END OPENSSH PRIV''ATE KEY-----'
  body='b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtz'

  mkdir -p "$work/bare" "$work/waived"
  printf '%s\n%s\n%s\n' "$pem_begin" "$body" "$pem_end" > "$work/bare/id_leak"
  printf '%s  secret-scan:allow\n%s\n%s  secret-scan:allow\n' \
    "$pem_begin" "$body" "$pem_end" > "$work/waived/id_leak"

  # Exit status is the assertion, so capture it directly: a pipe would report
  # the last command in the pipeline instead.
  rc=0; gitleaks dir "$work/bare" -c "$cfg" --no-banner --redact >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "gitleaks did not flag an unmarked private key (exit $rc, expected 1)"
  ok "an unmarked secret fails the gate"

  rc=0; gitleaks dir "$work/waived" -c "$cfg" --no-banner --redact >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || fail "the 'secret-scan:allow' marker did not waive its line (exit $rc, expected 0)"
  ok "the same secret, marked, passes the gate"
else
  if [ -n "${STRICT:-}" ]; then fail "gitleaks unavailable and STRICT=1 - allowlist behaviour not tested"; fi
  echo "SKIP: gitleaks unavailable - allowlist behaviour not tested"
fi

echo "PASS: gitleaks_gate_test ($pass assertions)"
