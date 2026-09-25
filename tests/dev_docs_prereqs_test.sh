#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Drift test: every tool ci.yml's "Ensure gate tools" setup loop installs must
# be named in docs/development.md's Prerequisites section. The loop
# (`for tool in ...`) is the single place that decides what CI provisions; if
# a tool is added there and forgotten in the docs, a contributor following the
# docs cannot reproduce CI locally. This closes that drift class statically,
# rather than relying on someone noticing the mismatch by hand.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
wf="$repo_root/.github/workflows/ci.yml"
docs="$repo_root/docs/development.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ok: $1"; }

[ -f "$wf" ] || fail "workflow not found: .github/workflows/ci.yml"
[ -f "$docs" ] || fail "docs not found: docs/development.md"

# Pull the tool list straight out of the loop line, e.g.
#   for tool in make shellcheck zsh tmux fzf jq; do
# rather than hardcoding the list here, so a tool added to the loop is picked
# up automatically and this test cannot go stale by omission.
loop_line="$(grep -E '^[[:space:]]*for tool in .*; do[[:space:]]*$' "$wf")" \
  || fail "no 'for tool in ...; do' loop found in ci.yml's gate-tools step"
[ "$(grep -cE '^[[:space:]]*for tool in .*; do[[:space:]]*$' "$wf")" -eq 1 ] \
  || fail "more than one 'for tool in ...; do' loop in ci.yml - this test reads only the first"
ok "found the gate-tools loop in ci.yml"

tools="$(sed -E 's/^[[:space:]]*for tool in (.*); do[[:space:]]*$/\1/' <<<"$loop_line")"
[ -n "$tools" ] || fail "could not parse the tool list out of: $loop_line"

# Scope the check to the Prerequisites section only (between its heading and
# the next '## ' heading), so a tool name that happens to appear elsewhere in
# the page (a gate table, a troubleshooting note) does not mask a real gap.
section="$(awk '/^## Prerequisites$/{p=1; next} /^## /{p=0} p' "$docs")"
[ -n "$section" ] || fail "docs/development.md has no '## Prerequisites' section"
ok "found the Prerequisites section in docs/development.md"

missing=""
for tool in $tools; do
  grep -q -F -- "$tool" <<<"$section" || missing="$missing $tool"
done
[ -z "$missing" ] \
  || fail "ci.yml's gate-tools loop names a tool the Prerequisites section never mentions:$missing"
ok "every tool in ci.yml's gate-tools loop ($tools) is named in the Prerequisites section"

echo "PASS: dev_docs_prereqs_test ($pass assertions)"
