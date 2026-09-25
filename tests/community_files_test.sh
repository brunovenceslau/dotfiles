#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Contract tests for the community health files and the Dependabot config.
#
# Two classes rot silently here and neither has a runtime symptom, so both are
# closed statically:
#
#   1. A missing health file. GitHub's community profile degrades quietly - a
#      deleted CONTRIBUTING.md or issue form costs nothing at merge time and is
#      noticed only by the stranger it was written for. The list below is the
#      set the repository commits to having.
#   2. A second Dependabot ecosystem. `gitsubmodule` would put automated bumps
#      of the three pinned zsh plugins into the review queue, and a plugin pin
#      is a SECURITY-MODEL surface: CLAUDE.md gates it ask-first, and
#      bin/check-patterns encodes premises about the shapes the startup shims
#      assume inside each plugin, which a bump can invalidate without failing
#      any other test. One line in a YAML file is all it takes to turn that
#      into a bot's decision, so the allowed set is asserted, not the
#      forbidden one: a new ecosystem of ANY name fails here.
#
# PyYAML is used for the structural half when it is importable; the grep floor
# always runs, so the file's shape is still checked on a machine with nothing
# installed. Here-strings, never `printf | grep` - the SIGPIPE-under-pipefail
# footgun the repo documents.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ok: $1"; }

# --- Every community health file is present -----------------------------------
# COPYING is in the list because GitHub's licence detection reads a ROOT
# COPYING or LICENSE and does not look inside LICENSES/.
missing=""
for f in \
  README.md \
  CONTRIBUTING.md \
  CODE_OF_CONDUCT.md \
  SECURITY.md \
  COPYING \
  .github/CODEOWNERS \
  .github/PULL_REQUEST_TEMPLATE.md \
  .github/ISSUE_TEMPLATE/config.yml \
  .github/ISSUE_TEMPLATE/bug_report.yml \
  .github/ISSUE_TEMPLATE/feature_request.yml \
  .github/dependabot.yml
do
  [ -f "$f" ] || missing="$missing $f"
done
[ -z "$missing" ] || fail "community health file missing:$missing"
ok "every community health file is present"

# --- Each of them is tracked by git -------------------------------------------
# A file that exists only in the working tree helps nobody on github.com.
untracked=""
for f in CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md .github/CODEOWNERS \
         .github/PULL_REQUEST_TEMPLATE.md .github/dependabot.yml
do
  git ls-files --error-unmatch "$f" >/dev/null 2>&1 || untracked="$untracked $f"
done
[ -z "$untracked" ] || fail "community health file not tracked by git:$untracked"
ok "the community health files are tracked"

# --- Dependabot: github-actions is the ONLY ecosystem -------------------------
# Comment lines are stripped first: this file's own header comment explains at
# length why gitsubmodule is absent, and that prose must never read as config.
db=".github/dependabot.yml"
db_code="$(grep -vE '^[[:space:]]*#' "$db")"
ecosystems="$(grep -E 'package-ecosystem:' <<<"$db_code" \
              | sed -E 's/.*package-ecosystem:[[:space:]]*"?([A-Za-z0-9_-]+)"?.*/\1/' \
              | sort -u)"
[ -n "$ecosystems" ] || fail "$db declares no package-ecosystem at all"
[ "$ecosystems" = "github-actions" ] \
  || fail "$db must declare github-actions and nothing else; found: $(tr '\n' ' ' <<<"$ecosystems")"
ok "dependabot.yml declares exactly one ecosystem: github-actions"

# --- Dependabot: gitsubmodule specifically, with the reason in the message ----
# Redundant with the assertion above on purpose. That one says "unexpected
# ecosystem"; this one says WHY this particular ecosystem is the one that must
# never appear, at the moment someone adds it.
if grep -qiE 'package-ecosystem:[[:space:]]*"?gitsubmodule' <<<"$db_code"; then
  fail "the gitsubmodule ecosystem is forbidden: the three zsh plugin pins are a security-model surface, bumped by hand per docs/development.md 'Bump a plugin pin'"
fi
ok "dependabot.yml does not enable the gitsubmodule ecosystem"

# --- Dependabot: the schedule is weekly ---------------------------------------
grep -qE 'interval:[[:space:]]*"?weekly' <<<"$db_code" \
  || fail "$db must schedule the github-actions ecosystem weekly"
ok "dependabot.yml schedules updates weekly"

# --- The issue chooser has blank issues off -----------------------------------
# A blank issue is how the required fields of both forms get skipped.
cfg=".github/ISSUE_TEMPLATE/config.yml"
grep -qE '^blank_issues_enabled:[[:space:]]*false[[:space:]]*$' "$cfg" \
  || fail "$cfg must set blank_issues_enabled: false"
ok "blank issues are disabled"

# --- The issue chooser links the private advisory form ------------------------
# The only reporting channel SECURITY.md names. A public issue is exactly what
# this link exists to prevent, so it is asserted rather than trusted.
advisory="https://github.com/brunovenceslau/dotfiles/security/advisories/new"
grep -qF "$advisory" "$cfg" \
  || fail "$cfg must link the private vulnerability advisory form"
grep -qF "$advisory" SECURITY.md \
  || fail "SECURITY.md must name the private vulnerability advisory form"
ok "the private advisory form is linked from the issue chooser and SECURITY.md"

# --- CODEOWNERS covers every path ---------------------------------------------
# A CODEOWNERS with no catch-all silently assigns no reviewer to new paths.
grep -qE '^\*[[:space:]]+@[A-Za-z0-9-]+' .github/CODEOWNERS \
  || fail ".github/CODEOWNERS must carry a catch-all '* @owner' rule"
ok "CODEOWNERS carries a catch-all rule"

# --- The Code of Conduct keeps its upstream attribution -----------------------
# CODE_OF_CONDUCT.md is the Contributor Covenant under CC BY-SA 4.0. That
# licence requires the attribution to survive, and reuse_gate_test.sh separately
# requires LICENSES/CC-BY-SA-4.0.txt to exist because the file names it.
grep -qF "Contributor Covenant" CODE_OF_CONDUCT.md \
  || fail "CODE_OF_CONDUCT.md must keep its Contributor Covenant attribution"
# REUSE-IgnoreStart
# The pattern below is a regex, not a licence declaration for THIS file.
# Without these two markers `reuse lint` reads it as a malformed SPDX
# expression and fails on the test that guards the licensing.
#
# The dot is deliberately NOT escaped. tests/reuse_gate_test.sh sweeps the tree
# for `SPDX-License-Identifier: <id>` and demands a matching LICENSES/<id>.txt;
# its id character class stops at a backslash, so `CC-BY-SA-4\.0` here would
# make it hunt for a licence called `CC-BY-SA-4`. An unescaped dot matches one
# character, which on this line is the dot itself.
grep -qE '^SPDX-License-Identifier: CC-BY-SA-4.0$' CODE_OF_CONDUCT.md \
  || fail "CODE_OF_CONDUCT.md must carry the CC-BY-SA-4.0 SPDX header"
# REUSE-IgnoreEnd
if grep -qE '\[NOTE:' CODE_OF_CONDUCT.md; then
  fail "CODE_OF_CONDUCT.md still carries an unfilled Contributor Covenant placeholder"
fi
ok "the Code of Conduct keeps its attribution and has no unfilled placeholder"

# --- Structural half: the YAML parses and says what the greps assumed ---------
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$db" "$cfg" <<'PY' || fail "PyYAML structural checks failed (see above)"
import sys, yaml

db_path, cfg_path = sys.argv[1], sys.argv[2]
errors = []

with open(db_path, encoding="utf-8") as fh:
    db = yaml.safe_load(fh)
if db.get("version") != 2:
    errors.append("dependabot.yml: version must be 2")
updates = db.get("updates") or []
if not updates:
    errors.append("dependabot.yml: no updates entries")
ecos = sorted({u.get("package-ecosystem") for u in updates})
if ecos != ["github-actions"]:
    errors.append("dependabot.yml: ecosystems are %r, expected ['github-actions']" % (ecos,))
for u in updates:
    if (u.get("schedule") or {}).get("interval") != "weekly":
        errors.append("dependabot.yml: %s is not scheduled weekly" % u.get("package-ecosystem"))

with open(cfg_path, encoding="utf-8") as fh:
    cfg = yaml.safe_load(fh)
if cfg.get("blank_issues_enabled") is not False:
    errors.append("config.yml: blank_issues_enabled must be the boolean false")
for link in cfg.get("contact_links") or []:
    for key in ("name", "url", "about"):
        if not link.get(key):
            errors.append("config.yml: a contact_link is missing %r" % key)

for form in ("bug_report", "feature_request"):
    path = ".github/ISSUE_TEMPLATE/%s.yml" % form
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    for key in ("name", "description", "body"):
        if not doc.get(key):
            errors.append("%s: missing top-level %r" % (path, key))
    for i, item in enumerate(doc.get("body") or []):
        if not item.get("type"):
            errors.append("%s: body[%d] has no type" % (path, i))
        if item.get("type") != "markdown" and not item.get("id"):
            errors.append("%s: body[%d] is an input with no id" % (path, i))

for e in errors:
    print("  " + e, file=sys.stderr)
sys.exit(1 if errors else 0)
PY
  ok "dependabot.yml, the issue chooser and both issue forms are structurally valid"
else
  if [ -n "${STRICT:-}" ]; then
    fail "python3+PyYAML unavailable and STRICT=1 - the .github YAML was not parsed"
  fi
  echo "  SKIP: python3+PyYAML unavailable - .github YAML not structurally checked"
fi

echo "PASS: community_files_test ($pass assertions)"
