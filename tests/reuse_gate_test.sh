#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Wiring tests for the `make reuse` licensing gate. The gate itself is
# `reuse lint`, which has its own test suite upstream; what can rot here is the
# WIRING, and it rots silently: a gate that is not a local-ci prerequisite runs
# nowhere, and a gate that skips instead of failing under STRICT=1 reports green
# on a check that never executed. Both classes are asserted statically, so they
# are caught without the tool being installed.
#
# The licensing FACTS the gate protects are asserted too: the four licences the
# tree names must each have their text under LICENSES/, and the root COPYING
# must be the GPL text GitHub's licence detection reads (it does not look inside
# LICENSES/).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mk="$repo_root/Makefile"
wf="$repo_root/.github/workflows/ci.yml"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ok: $1"; }

# --- Wiring: the target exists and runs the linter -----------------------------
grep -Eq '^reuse:' "$mk" || fail "Makefile has no 'reuse' target"
grep -q 'reuse lint' "$mk" || fail "Makefile 'reuse' target must call 'reuse lint'"
ok "Makefile defines a 'reuse' target that runs 'reuse lint'"

# --- Wiring: reuse is a local-ci prerequisite ----------------------------------
# A blocking gate MUST be reachable from local-ci, or `make local-ci` before a
# push proves nothing about it. Same assertion shape as the smoke test's.
# grep -w is supported by GNU and macOS BSD grep.
if ! grep -qw reuse <<<"$(grep -E '^local-ci:' "$mk")"; then
  fail "reuse must be a local-ci prerequisite (it is a blocking gate)"
fi
ok "reuse is a local-ci prerequisite"

# --- Wiring: STRICT=1 fails closed ---------------------------------------------
# Two separate greps rather than one combined pattern, so the failure message
# says which half is missing.
recipe="$(awk '/^reuse:/{p=1; next} /^[^\t]/{p=0} p' "$mk")"
[ -n "$recipe" ] || fail "could not read the 'reuse' target's recipe out of the Makefile"
grep -q 'STRICT' <<<"$recipe" \
  || fail "the 'reuse' recipe ignores STRICT - a missing tool would skip even in CI"
grep -q 'exit 1' <<<"$recipe" \
  || fail "the 'reuse' recipe must exit 1 under STRICT=1 when reuse is absent"
ok "the 'reuse' recipe fails closed under STRICT=1"

# --- Wiring: CI provisions the tool --------------------------------------------
# local-ci runs under STRICT=1 in CI, so a gate CI cannot install is a red leg.
# The gate-tools loop is the single place that decides what CI provisions;
# tests/dev_docs_prereqs_test.sh then holds the docs to that same list.
grep -qw reuse <<<"$(grep -E '^[[:space:]]*for tool in .*; do[[:space:]]*$' "$wf")" \
  || fail "ci.yml's gate-tools loop does not install reuse, which local-ci STRICT=1 requires"
ok "ci.yml's gate-tools loop installs reuse"

# --- Facts: every licence the tree names has its text under LICENSES/ ----------
# Derived from the tree, not hardcoded, so a new SPDX identifier in any file is
# caught the moment it lands without its text.
#
# REUSE-IgnoreStart
# The pattern below is a regex, not a licence declaration. Without these two
# markers `reuse lint` reads it as a malformed SPDX expression and fails on
# this very file - the gate tripping over its own test.
cd "$repo_root"
ids="$(git grep -h -o -E 'SPDX-License-Identifier: [A-Za-z0-9.+-]+' \
         -- . ':!LICENSES' ':!tests/reuse_gate_test.sh' \
       | sed -E 's/.*: //' | sort -u)"
# REUSE-IgnoreEnd
[ -n "$ids" ] || fail "no SPDX-License-Identifier tag found anywhere in the tree"
missing=""
for id in $ids; do
  [ -f "LICENSES/$id.txt" ] || missing="$missing $id"
done
[ -z "$missing" ] || fail "licence named in the tree with no text in LICENSES/:$missing"
ok "every licence the tree names has its text in LICENSES/ ($(tr '\n' ' ' <<<"$ids"))"

# --- Facts: the root COPYING is the GPL text -----------------------------------
# GitHub's licence detection reads a root COPYING or LICENSE and does not look
# inside LICENSES/, so the duplicate is deliberate. Compared by content: a
# COPYING that drifted from the LICENSES/ copy would show two different licences
# for one repository.
[ -f COPYING ] || fail "no root COPYING - GitHub's licence detection needs one"
cmp -s COPYING LICENSES/GPL-3.0-or-later.txt \
  || fail "COPYING differs from LICENSES/GPL-3.0-or-later.txt"
ok "the root COPYING is byte-identical to LICENSES/GPL-3.0-or-later.txt"

# --- Facts: every tracked JSON file is declared in REUSE.toml -----------------
# JSON has no comment syntax, so these cannot carry a header; REUSE.toml is the
# only place that indirection is allowed, and a new JSON file that forgets it
# would fail `reuse lint` only where reuse is installed.
for f in $(git ls-files '*.json'); do
  grep -q "\"$f\"" REUSE.toml \
    || fail "$f cannot carry a header and is not declared in REUSE.toml"
done
ok "every tracked .json file is declared in REUSE.toml"

echo "PASS: reuse_gate_test ($pass assertions)"
