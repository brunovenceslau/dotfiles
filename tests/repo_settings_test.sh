#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# The OFFLINE half of the settings-vs-docs drift gate, and the offline proof of
# the ONLINE half's diff logic.
#
# .github/repo-settings.json is the single statement of the GitHub settings the
# repository relies on. Before it existed, the docs claimed server-side
# protections that were not configured (docs/development.md, "Docs described
# GitHub settings the repository did not have"). This test runs in every pull
# request, forks included, with no network and no token, and fails when:
#   1. the settings file is malformed or missing a section;
#   2. the required status checks in the file are not exactly the check names
#      .github/workflows/ci.yml generates (a renamed job or matrix leg would
#      otherwise leave a required check that can never report);
#   3. a doc sentence that claims a setting is gone or reworded (its anchor
#      below no longer matches), or the file no longer holds the value that
#      sentence claims;
#   4. a doc names a `local-ci (...)` check the file does not require, or
#      CONTRIBUTING.md omits one it does;
#   5. a tracked doc talks about these settings but has no anchor here, so a new
#      claim cannot land unchecked.
# Whether the LIVE repository matches the file is bin/repo-settings-check's job
# (`make repo-settings-check`, maintainer-run). Part B below proves its diff
# logic against a stubbed `gh`: a match passes, drift fails 1, and an endpoint
# it cannot read fails 2 and is never reported `ok`.
#
# Runs under the macOS /bin/bash 3.2 (make test), so: no associative arrays, no
# mapfile, and here-strings rather than pipes into grep -q (SIGPIPE under
# pipefail).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
settings="$repo_root/.github/repo-settings.json"
wf="$repo_root/.github/workflows/ci.yml"
tool="$repo_root/bin/repo-settings-check"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

# jq reads the file on both halves; it is a listed gate prerequisite, so a
# missing jq is a hard failure under STRICT=1 rather than a quiet skip.
if ! command -v jq >/dev/null 2>&1; then
  [ -z "${STRICT:-}" ] || fail "jq not installed and STRICT=1 - repo settings checks not run"
  echo "SKIP: jq not installed - repo settings checks not run"
  exit 0
fi

# === Part A: the file, ci.yml and the docs agree =============================

# --- A1. shape ---------------------------------------------------------------
[ -f "$settings" ] || fail "missing .github/repo-settings.json"
jq -e '
  (.repository | type == "string" and test("^[^/]+/[^/]+$"))
  and (.repo.default_branch | type == "string" and length > 0)
  and (.private_vulnerability_reporting.enabled | type == "boolean")
  and (.actions_permissions.sha_pinning_required | type == "boolean")
  and (.fork_pr_contributor_approval.approval_policy
       | IN("first_time_contributors_new_to_github", "first_time_contributors", "all_external_contributors"))
  and (.ruleset.name | type == "string" and length > 0)
  and (.ruleset.enforcement | IN("disabled", "active", "evaluate"))
  and ([.ruleset.include, .ruleset.exclude, .ruleset.bypass_actors, .ruleset.rules]
       | all(type == "array"))
  and (.ruleset.required_status_checks | type == "array" and length > 0
       and all(type == "object" and (.context | type == "string")))
  and (.ruleset.status_check_policy | type == "object")
' "$settings" >/dev/null || fail ".github/repo-settings.json is malformed or misses a section (see A1 in this test)"
ok "settings file is well-formed (approval_policy and enforcement are documented enum values)"

# --- A2. required checks == the check names ci.yml generates -----------------
# GitHub names a job's check `name:` with matrix expressions expanded per leg,
# or the job id when there is no `name:`. PyYAML is a CI prerequisite.
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  generated="$(python3 - "$wf" <<'PY'
import re, sys, yaml
with open(sys.argv[1]) as f:
    jobs = yaml.safe_load(f)["jobs"]
expr = re.compile(r"\$\{\{ *matrix\.([A-Za-z0-9_-]+) *\}\}")
for jid, job in jobs.items():
    name = str(job.get("name", jid))
    matrix = (job.get("strategy") or {}).get("matrix") or {}
    if not matrix:
        print(name)
        continue
    axes = [k for k in matrix if k not in ("include", "exclude")]
    if not expr.search(name):
        sys.exit(f"job {jid!r} runs a matrix but its name has no matrix expression; "
                 "GitHub then appends the matrix values to the check name - extend this test")
    if axes:
        sys.exit(f"job {jid!r}: matrix axes {axes} are not expanded by this test - extend it")
    for leg in matrix.get("include") or []:
        print(expr.sub(lambda m: str(leg[m.group(1)]), name))
PY
)" || fail "could not derive the check names from ci.yml"
  generated="$(sort <<<"$generated")"
  required="$(jq -r '.ruleset.required_status_checks[].context' "$settings" | sort)"
  if [ "$generated" != "$required" ]; then
    printf 'ci.yml generates:\n%s\nrepo-settings.json requires:\n%s\n' "$generated" "$required" >&2
    fail "required status checks disagree with the job names ci.yml generates"
  fi
  ok "required status checks are exactly the check names ci.yml generates"
else
  [ -z "${STRICT:-}" ] || fail "PyYAML unavailable and STRICT=1 - ci.yml check names not derived"
  echo "SKIP: PyYAML unavailable - ci.yml check names not derived"
fi

# --- A3. every doc claim is anchored and holds in the file -------------------
# One row per claim: FILE | PHRASE (whitespace-normalized) | jq predicate over
# the settings file. Reword a claim and its row must move with it; change the
# file and every sentence claiming the old value fails here.
prelude='def rule($r): .ruleset.rules | index($r) != null;
def on_main: .ruleset.enforcement == "active"
  and ((.ruleset.include | index("refs/heads/main") != null)
       or (.ruleset.include | index("~DEFAULT_BRANCH") != null));
def pvr: .private_vulnerability_reporting.enabled == true;'
anchors='CONTRIBUTING.md|Every commit on `main` must carry a valid signature. A branch ruleset on `main` enforces it on the server, with no bypass actors|on_main and rule("required_signatures") and .ruleset.bypass_actors == []
CONTRIBUTING.md|The same ruleset blocks force pushes to `main` and blocks deleting it|on_main and rule("non_fast_forward") and rule("deletion")
CONTRIBUTING.md|are required status checks in the `main` ruleset.|on_main and rule("required_status_checks")
CONTRIBUTING.md|Merges use a merge commit.** Squash and rebase merging are off|.repo.allow_merge_commit == true and .repo.allow_squash_merge == false and .repo.allow_rebase_merge == false
CONTRIBUTING.md|The head branch is deleted automatically after the merge.|.repo.delete_branch_on_merge == true
CONTRIBUTING.md|Actions setting requires maintainer approval before any workflow runs on a pull request from an outside collaborator (anyone without write access).|.fork_pr_contributor_approval.approval_policy == "all_external_contributors"
SECURITY.md|Report privately through GitHub, never in a public issue or pull request|pvr
SECURITY.md|<https://github.com/brunovenceslau/dotfiles/security/advisories/new>|pvr and .repository == "brunovenceslau/dotfiles"
README.md|use the private advisory form linked from|pvr
.github/ISSUE_TEMPLATE/config.yml|url: https://github.com/brunovenceslau/dotfiles/security/advisories/new|pvr
.github/ISSUE_TEMPLATE/bug_report.yml|Use the private advisory|pvr
docs/stacked-prs.md|This repository has `delete_branch_on_merge` enabled.|.repo.delete_branch_on_merge == true
docs/stacked-prs.md|verified-signatures branch rule then rejects them|rule("required_signatures")
docs/development.md|the repository'"'"'s Actions settings require SHA pinning|.actions_permissions.sha_pinning_required == true
docs/development.md|Both legs are required status checks on `main`|on_main and rule("required_status_checks") and (.ruleset.required_status_checks | length) == 2
docs/development.md|the requirement lives in the branch ruleset rather than in the workflow|rule("required_status_checks")'
n=0
while IFS='|' read -r file phrase pred; do
  [ -f "$repo_root/$file" ] || fail "anchor file $file is gone - move its claims' anchors"
  norm="$(tr -s '[:space:]' ' ' <"$repo_root/$file")"
  grep -qF -- "$phrase" <<<"$norm" \
    || fail "$file no longer says: \"$phrase\" - reworded or moved? Update the anchor in this test and .github/repo-settings.json together"
  jq -e "$prelude $pred" "$settings" >/dev/null \
    || fail "$file claims \"$phrase\" but .github/repo-settings.json does not hold it ($pred)"
  n=$((n + 1))
done <<<"$anchors"
ok "$n doc claims anchored and consistent with the settings file"

# --- A4. check names quoted in docs --------------------------------------------
docs="$(cd "$repo_root" && git ls-files '*.md' '.github/ISSUE_TEMPLATE/*')"
[ -n "$docs" ] || fail "git ls-files found no docs (not a git checkout?)"
required="$(jq -r '.ruleset.required_status_checks[].context' "$settings")"
quoted="$(cd "$repo_root" && grep -ohE '`local-ci \([A-Za-z0-9._-]+\)`' $docs | tr -d '`' | sort -u || true)"
while IFS= read -r c; do
  [ -n "$c" ] || continue
  grep -qxF -- "$c" <<<"$required" || fail "a doc names the check \"$c\", which .github/repo-settings.json does not require"
done <<<"$quoted"
contributing="$(tr -s '[:space:]' ' ' <"$repo_root/CONTRIBUTING.md")"
while IFS= read -r c; do
  grep -qF -- "\`$c\`" <<<"$contributing" || fail "CONTRIBUTING.md does not name the required check \"$c\""
done <<<"$required"
ok "every check name a doc quotes is required, and CONTRIBUTING.md names every required check"

# --- A5. no unanchored settings talk --------------------------------------------
# A doc that mentions these settings but has no anchor row above is a claim
# nothing checks. The regex is deliberately broad; a false hit costs one anchor.
# KNOWN LIMIT: this is FILE-level. A new claim added to a file that already has
# an anchor (CONTRIBUTING.md, README.md, ...) passes here unchecked; only its
# review, or a reworded existing anchor, catches it.
kw='ruleset|required status check|delete_branch_on_merge|squash (and rebase )?merg|rebase merg|sha pinning|approval_policy|fork-pr-contributor|security/advisories|private advisory|vulnerability report|merge commit|bypass actor|verified-signatures'
anchored="$(cut -d'|' -f1 <<<"$anchors" | sort -u)"
hits="$(cd "$repo_root" && grep -liE "$kw" $docs || true)"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -qxF -- "$f" <<<"$anchored" \
    || fail "$f talks about GitHub settings but has no anchor in tests/repo_settings_test.sh (A3) - add one"
done <<<"$hits"
ok "every doc that mentions a GitHub setting is anchored"

# === Part B: bin/repo-settings-check's diff logic against a stubbed gh ======

[ -x "$tool" ] || fail "bin/repo-settings-check missing or not executable"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/fx"

# The stub answers `gh api PATH` from $work/fx: PATH with its query dropped and
# every / turned into _, then .json (a 200 body) or .err (stderr + exit 1, the
# way gh reports HTTP >= 400). Anything else is a 404. `--paginate` is accepted
# and the file is printed as-is, so a fixture holding several concatenated
# arrays is exactly what gh prints for several pages. Every call is logged, so
# the test can prove the tool only ever issues plain GETs.
cat >"$work/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_STUB_DIR/calls.log"
[ "${1:-}" = api ] || { echo "stub gh: unexpected call: $*" >&2; exit 64; }
shift
[ "${1:-}" != --paginate ] || shift
[ "$#" -eq 1 ] || { echo "stub gh: unexpected call" >&2; exit 64; }
k="$(tr '/' '_' <<<"${1%%\?*}")"
if [ -f "$GH_STUB_DIR/$k.err" ]; then cat "$GH_STUB_DIR/$k.err" >&2; exit 1; fi
if [ -f "$GH_STUB_DIR/$k.json" ]; then cat "$GH_STUB_DIR/$k.json"; exit 0; fi
echo "gh: Not Found (HTTP 404)" >&2; exit 1
SH
chmod u+x "$work/bin/gh"

# A fixed expected file, independent of the real one, so a legitimate settings
# change never breaks the diff-logic cases below. 19 rows: repo 4, three
# single-key endpoints, ruleset name + 8 fields, branch 3.
cat >"$work/settings.json" <<'JSON'
{
  "repository": "o/r",
  "repo": {"default_branch": "main", "allow_merge_commit": true, "allow_squash_merge": false, "has_wiki": false},
  "private_vulnerability_reporting": {"enabled": true},
  "actions_permissions": {"sha_pinning_required": true},
  "fork_pr_contributor_approval": {"approval_policy": "all_external_contributors"},
  "ruleset": {
    "name": "main-protection", "target": "branch", "enforcement": "active",
    "include": ["refs/heads/main"], "exclude": [], "bypass_actors": [],
    "rules": ["deletion", "non_fast_forward", "required_signatures", "required_status_checks"],
    "required_status_checks": [{"context": "local-ci (b)"}, {"context": "local-ci (a)"}],
    "status_check_policy": {"strict_required_status_checks_policy": false, "do_not_enforce_on_create": false}
  }
}
JSON

# Live-shaped responses (the shapes the real API returned on 2026-09-25),
# with extra fields the tool must ignore. Rules and checks are out of order on
# purpose: both are compared as sets.
fixtures_match() {
  rm -f "$work/fx"/*
  cat >"$work/fx/repos_o_r.json" <<'JSON'
{"full_name":"o/r","default_branch":"main","allow_merge_commit":true,"allow_squash_merge":false,"allow_rebase_merge":false,"has_wiki":false,"permissions":{"admin":true}}
JSON
  echo '{"enabled":true}' >"$work/fx/repos_o_r_private-vulnerability-reporting.json"
  echo '{"enabled":true,"allowed_actions":"all","sha_pinning_required":true}' >"$work/fx/repos_o_r_actions_permissions.json"
  echo '{"approval_policy":"all_external_contributors"}' >"$work/fx/repos_o_r_actions_permissions_fork-pr-contributor-approval.json"
  echo '[{"id":7,"name":"other"},{"id":42,"name":"main-protection","enforcement":"active"}]' >"$work/fx/repos_o_r_rulesets.json"
  cat >"$work/fx/repos_o_r_rulesets_42.json" <<'JSON'
{"id":42,"name":"main-protection","target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"exclude":[],"include":["refs/heads/main"]}},
 "rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,
   "do_not_enforce_on_create":false,
   "required_status_checks":[{"context":"local-ci (a)"},{"context":"local-ci (b)"}]}},
   {"type":"required_signatures"},{"type":"deletion"},{"type":"non_fast_forward"}],
 "bypass_actors":[],"current_user_can_bypass":"never"}
JSON
  cat >"$work/fx/repos_o_r_rules_branches_main.json" <<'JSON'
[{"type":"required_signatures","ruleset_source_type":"Repository","ruleset_source":"o/r","ruleset_id":42},
 {"type":"required_status_checks","ruleset_source_type":"Repository","ruleset_source":"o/r","ruleset_id":42,
  "parameters":{"required_status_checks":[{"context":"local-ci (a)"},{"context":"local-ci (b)"}]}},
 {"type":"non_fast_forward","ruleset_source_type":"Repository","ruleset_source":"o/r","ruleset_id":42},
 {"type":"deletion","ruleset_source_type":"Repository","ruleset_source":"o/r","ruleset_id":42}]
JSON
  # gh's exact wording for an unprotected branch (live, 2026-09-25).
  echo 'gh: Branch not protected (HTTP 404)' >"$work/fx/repos_o_r_branches_main_protection.err"
}

# edit FIXTURE JQ - rewrite one fixture in place.
edit() { jq -c "$2" "$work/fx/$1.json" >"$work/fx/$1.tmp" && mv "$work/fx/$1.tmp" "$work/fx/$1.json"; }

rc=0
out=""
run_tool() {
  rm -f "$work/fx/calls.log"
  rc=0
  out="$(PATH="$work/bin:$PATH" GH_STUB_DIR="$work/fx" "$tool" "$work/settings.json" 2>&1)" || rc=$?
}
row_is() { grep -qE "^$1[[:space:]]+$2[[:space:]]" <<<"$out"; }
# expect_run LABEL RC COUNTS [STATUS SETTING_RE]... - run, then assert the exit
# code, the summary counts and each named row's status.
expect_run() {
  local label="$1" want_rc="$2" counts="$3"
  shift 3
  run_tool
  [ "$rc" -eq "$want_rc" ] || { echo "$out" >&2; fail "$label: expected exit $want_rc, got $rc"; }
  grep -qF "$counts" <<<"$out" || { echo "$out" >&2; fail "$label: expected '$counts'"; }
  while [ "$#" -ge 2 ]; do
    row_is "$1" "$2" || { echo "$out" >&2; fail "$label: row $2 is not $1"; }
    shift 2
  done
  ok "stubbed $label: exit $want_rc, $counts"
}

# B1. match -> exit 0, every row ok, and only plain GETs were issued.
fixtures_match
expect_run "match" 0 "19 ok, 0 drift, 0 unreadable"
grep -vqE '^api (--paginate )?[^ ]+$' "$work/fx/calls.log" && fail "the tool issued a gh call other than a plain 'gh api [--paginate] PATH' GET"
grep -qE '^api --paginate repos/o/r/rules/branches/main' "$work/fx/calls.log" || fail "the effective-rules list is not read with --paginate"
grep -qE '^api --paginate repos/o/r/rulesets[?]' "$work/fx/calls.log" || fail "the rulesets list is not read with --paginate"
ok "stubbed match: only plain GET calls"

# B2. drift -> exit 1, exactly the drifted rows are DRIFT.
fixtures_match
edit repos_o_r '.allow_squash_merge = true'
edit repos_o_r_rulesets_42 '.rules[0].parameters.required_status_checks |= map(select(.context != "local-ci (b)"))'
expect_run "drift" 1 "17 ok, 2 drift, 0 unreadable" \
  DRIFT 'repo\.allow_squash_merge' DRIFT 'ruleset\.required_status_checks'

# B3. unreadable -> exit 2, and the unreadable rows are never `ok`.
fixtures_match
rm "$work/fx/repos_o_r_actions_permissions_fork-pr-contributor-approval.json"
echo 'gh: Must have admin rights to Repository. (HTTP 403)' >"$work/fx/repos_o_r_actions_permissions_fork-pr-contributor-approval.err"
edit repos_o_r_rulesets_42 'del(.bypass_actors)'
edit repos_o_r 'del(.allow_squash_merge)'
expect_run "unreadable" 2 "16 ok, 0 drift, 3 unreadable" \
  UNREADABLE 'fork_pr_contributor_approval\.approval_policy' UNREADABLE 'ruleset\.bypass_actors' \
  UNREADABLE 'repo\.allow_squash_merge'
grep -qF 'HTTP 403' <<<"$out" || fail "unreadable: gh's error was not surfaced"

# B4. drift wins over unreadable: exit 1 when both happen.
edit repos_o_r '.has_wiki = true'
expect_run "drift plus unreadable" 1 "15 ok, 1 drift, 3 unreadable" DRIFT 'repo\.has_wiki'

# B5. unauthenticated -> every row UNREADABLE, zero ok, exit 2.
rm -f "$work/fx"/*
for k in repos_o_r repos_o_r_private-vulnerability-reporting repos_o_r_actions_permissions \
  repos_o_r_actions_permissions_fork-pr-contributor-approval repos_o_r_rulesets \
  repos_o_r_rules_branches_main repos_o_r_branches_main_protection; do
  echo 'gh: Bad credentials (HTTP 401)' >"$work/fx/$k.err"
done
expect_run "unauthenticated" 2 "0 ok, 0 drift, 18 unreadable" UNREADABLE 'branch\.main\.classic_protection'

# B6. ruleset renamed or deleted -> DRIFT on ruleset.name.
fixtures_match
echo '[{"id":7,"name":"other"}]' >"$work/fx/repos_o_r_rulesets.json"
expect_run "missing ruleset" 1 "1 drift" DRIFT 'ruleset\.name' UNREADABLE 'branch\.main\.rule_sources'

# B7. a second ruleset acting on the branch -> the effective rules name a
# foreign ruleset_id and an extra rule type.
fixtures_match
edit repos_o_r_rules_branches_main '. + [{"type":"pull_request","ruleset_source_type":"Organization","ruleset_source":"o","ruleset_id":99}]'
expect_run "extra ruleset on the branch" 1 "17 ok, 2 drift, 0 unreadable" \
  DRIFT 'branch\.main\.rule_sources' DRIFT 'branch\.main\.rule_types'
grep -qF 'ruleset id 99' <<<"$out" || fail "extra ruleset: the foreign ruleset id was not named"

# B7b. the foreign rule sits on page 2 of the effective rules: gh --paginate
# prints one array per page, and a reader of page 1 alone would report ok.
fixtures_match
echo '[{"type":"pull_request","ruleset_source_type":"Organization","ruleset_source":"o","ruleset_id":99}]' \
  >>"$work/fx/repos_o_r_rules_branches_main.json"
expect_run "foreign rule on page 2" 1 "17 ok, 2 drift, 0 unreadable" \
  DRIFT 'branch\.main\.rule_sources' DRIFT 'branch\.main\.rule_types'
# The same for the rulesets list: a second same-name ruleset on page 2 is
# ambiguous, never a silent pick of the page-1 one.
fixtures_match
echo '[{"id":43,"name":"main-protection"}]' >>"$work/fx/repos_o_r_rulesets.json"
expect_run "duplicate ruleset on page 2" 2 "0 drift" UNREADABLE 'ruleset\.name'

# B8. classic branch protection present -> DRIFT; a bare 404 (what a caller
# without rights also gets) is UNREADABLE, never proof of absence.
fixtures_match
rm "$work/fx/repos_o_r_branches_main_protection.err"
echo '{"url":"x","required_signatures":{"enabled":false}}' >"$work/fx/repos_o_r_branches_main_protection.json"
expect_run "classic protection present" 1 "18 ok, 1 drift" DRIFT 'branch\.main\.classic_protection'
rm "$work/fx/repos_o_r_branches_main_protection.json"
expect_run "classic protection bare 404" 2 "18 ok, 0 drift, 1 unreadable" UNREADABLE 'branch\.main\.classic_protection'

# B9. ruleset content drift the named-ruleset rows must catch.
fixtures_match
edit repos_o_r_rulesets_42 '.bypass_actors = [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]'
expect_run "extra bypass actor" 1 "18 ok, 1 drift" DRIFT 'ruleset\.bypass_actors'
fixtures_match
edit repos_o_r_rulesets_42 '.rules += [{"type":"creation"}]'
expect_run "extra rule" 1 "18 ok, 1 drift" DRIFT 'ruleset\.rules'
fixtures_match
edit repos_o_r_rulesets_42 '.conditions.ref_name.include = ["~DEFAULT_BRANCH"]'
expect_run "~DEFAULT_BRANCH condition" 1 "18 ok, 1 drift" DRIFT 'ruleset\.include'
fixtures_match
edit repos_o_r_rulesets_42 '.rules[0].parameters.required_status_checks[0].integration_id = 15368 | .rules[0].parameters.strict_required_status_checks_policy = true'
expect_run "integration_id and strict policy" 1 "17 ok, 2 drift" \
  DRIFT 'ruleset\.required_status_checks' DRIFT 'ruleset\.status_check_policy'

# B10. a 200 body that is not JSON, or not the documented shape -> UNREADABLE
# rows and exit 2, never jq's own rc 5 aborting the run.
fixtures_match
echo '<html>proxy error</html>' >"$work/fx/repos_o_r.json"
expect_run "non-JSON body" 2 "15 ok, 0 drift, 4 unreadable" UNREADABLE 'repo\.default_branch'
grep -qF 'unexpected response' <<<"$out" || fail "non-JSON: the row does not say the response was unexpected"
fixtures_match
echo '{"message":"moved"}' >"$work/fx/repos_o_r_rulesets.json"
echo '{"message":"moved"}' >"$work/fx/repos_o_r_rules_branches_main.json"
expect_run "wrong-shape rulesets" 2 "0 drift, 10 unreadable" \
  UNREADABLE 'ruleset\.rules' UNREADABLE 'ruleset\.bypass_actors' \
  UNREADABLE 'branch\.main\.rule_sources' UNREADABLE 'branch\.main\.rule_types'
fixtures_match
echo '[]' >"$work/fx/repos_o_r_rulesets_42.json"
expect_run "wrong-shape ruleset detail" 2 "0 drift, 8 unreadable" UNREADABLE 'ruleset\.rules'

# B11. no gh at all -> exit 2 with a clear message, never a pass. PATH holds
# only what the tool needs before its gh probe, so a gh on the host cannot leak in.
mkdir -p "$work/nogh"
for t in bash jq dirname; do ln -s "$(command -v "$t")" "$work/nogh/$t"; done
rc=0
out="$(PATH="$work/nogh" "$work/nogh/bash" "$tool" "$work/settings.json" 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || { echo "$out" >&2; fail "no gh: expected exit 2, got $rc"; }
grep -qF "gh not installed" <<<"$out" || { echo "$out" >&2; fail "no gh: message does not say gh is missing"; }
ok "no gh on PATH: exit 2 with a clear message"

echo "PASS: repo_settings_test"
