#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Contract tests for .github/workflows/release.yml + cliff.toml - the release
# path. Nothing else in the repository exercises them: the workflow runs once
# per tag, on a surface (`contents: write`, a downloaded binary, a published
# artifact) where a mistake is public and not cheap to take back. This test is
# the standing proof of its shape.
#
# The properties pinned here, each because losing it costs something concrete:
#   - the trigger is a version-tag push ONLY (a `pull_request` trigger would
#     hand `contents: write` to a fork's branch),
#   - `contents: write` lives on the release job and nowhere wider,
#   - every `uses:` is a GitHub-owned action pinned to a 40-hex SHA, and the
#     checkout pin is the SAME one ci.yml carries (they bump together),
#   - git-cliff arrives as a version-pinned, sha256-VERIFIED tarball in a
#     `run:` step - never a third-party action, never a floating `latest`,
#   - no `${{ }}` interpolation inside a `run:` block (script injection),
#   - the release is cut with `--verify-tag`, so a run can never invent a tag,
#   - no step is exit-suppressed, and
#   - cliff.toml keeps the two properties the notes depend on: conventional
#     commits only, and merge commits skipped.
#
# Shape follows tests/ci_workflow_test.sh: grep floors always run (here-strings,
# never `printf | grep` - the SIGPIPE-under-pipefail footgun the repo
# documents), PyYAML structural checks on top when the module is importable and
# a hard failure under STRICT=1.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
wf="$repo_root/.github/workflows/release.yml"
ci="$repo_root/.github/workflows/ci.yml"
cliff="$repo_root/cliff.toml"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ok: $1"; }

# --- Existence ----------------------------------------------------------------
[ -f "$wf" ] || fail "workflow not found: .github/workflows/release.yml"
[ -f "$cliff" ] || fail "cliff.toml not found - release.yml reads it for the notes"
ok "release.yml and cliff.toml exist"

# Non-comment lines only, so the header comment above - which necessarily names
# `uses:`, `pull_request` and the rest of what it forbids - is never read as
# workflow content.
commands="$(grep -vE '^[[:space:]]*#' "$wf")"

# --- Trigger: a version tag push, and nothing else ----------------------------
grep -Eq "^[[:space:]]*tags:[[:space:]]*\['v\*'\]" <<<"$commands" \
  || fail "release.yml must trigger on push tags: ['v*']"
grep -q 'pull_request' <<<"$commands" \
  && fail "release.yml carries a pull_request trigger - it would expose contents: write"
grep -q 'workflow_dispatch' <<<"$commands" \
  && fail "release.yml carries workflow_dispatch - a release must come from a signed tag"
ok "trigger is a push of a v* tag only"

# --- Runner + the write permission --------------------------------------------
grep -Eq '^[[:space:]]*runs-on:[[:space:]]*ubuntu-latest[[:space:]]*$' <<<"$commands" \
  || fail "release.yml must run on ubuntu-latest"
grep -Eq '^[[:space:]]*contents:[[:space:]]*write[[:space:]]*$' <<<"$commands" \
  || fail "release.yml must grant contents: write (gh release create needs it)"
[ "$(grep -cE '^[[:space:]]*contents:[[:space:]]*write[[:space:]]*$' <<<"$commands")" -eq 1 ] \
  || fail "contents: write appears more than once in release.yml - it belongs to one job"
ok "ubuntu-latest, with exactly one contents: write grant"

# --- Actions: GitHub-owned and SHA-pinned -------------------------------------
uses="$(grep -E '^[[:space:]]*(-[[:space:]]*)?uses:' <<<"$commands" || true)"
[ -n "$uses" ] || fail "release.yml uses no action at all - expected actions/checkout"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  grep -Eq 'uses:[[:space:]]*actions/[A-Za-z0-9._-]+@[0-9a-f]{40}([[:space:]]|$)' <<<"$line" \
    || fail "not a SHA-pinned GitHub-owned action: $line"
done <<<"$uses"
ok "every action is actions/* pinned to a 40-hex SHA"

# The two workflows pin the same checkout. A bump that updates one and not the
# other is a drift this catches at commit time, not at the next release.
wf_sha="$(grep -oE 'actions/checkout@[0-9a-f]{40}' <<<"$commands" | sed -n '1p')"
ci_sha="$(sed -n '1p' <<<"$(grep -oE 'actions/checkout@[0-9a-f]{40}' "$ci")")"
[ -n "$wf_sha" ] || fail "release.yml does not use actions/checkout"
[ -n "$ci_sha" ] || fail "ci.yml does not use actions/checkout - this test reads its pin"
[ "$wf_sha" = "$ci_sha" ] \
  || fail "checkout pins drifted: release.yml has $wf_sha, ci.yml has $ci_sha"
ok "release.yml and ci.yml pin the same actions/checkout ($wf_sha)"

# --- git-cliff: a pinned, checksum-verified binary, not an action -------------
grep -qi 'uses:.*cliff' <<<"$commands" \
  && fail "git-cliff must be a run: step, not an action (allowed actions are GitHub-owned)"
grep -Eq '^[[:space:]]*GIT_CLIFF_VERSION:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$' <<<"$commands" \
  || fail "release.yml must pin an exact GIT_CLIFF_VERSION (x.y.z)"
grep -Eq '^[[:space:]]*GIT_CLIFF_SHA256:[[:space:]]*[0-9a-f]{64}[[:space:]]*$' <<<"$commands" \
  || fail "release.yml must pin a 64-hex GIT_CLIFF_SHA256 for the downloaded asset"
grep -Eq 'sha256sum[[:space:]]+--check' <<<"$commands" \
  || fail "release.yml downloads git-cliff without verifying the sha256"
grep -q 'releases/latest' <<<"$commands" \
  && fail "release.yml downloads a floating 'latest' asset - pin the version"
grep -Eq 'curl[^|]*--fail' <<<"$commands" \
  || fail "the git-cliff download must use curl --fail (an error page would reach sha256sum)"
# The asset URL must be built from the pinned version, never from a literal
# that can drift away from GIT_CLIFF_VERSION/GIT_CLIFF_SHA256.
grep -Eq 'releases/download/v\$\{GIT_CLIFF_VERSION\}' <<<"$commands" \
  || fail "the git-cliff asset URL must interpolate GIT_CLIFF_VERSION"
ok "git-cliff is a version-pinned, sha256-verified tarball in a run: step"

# --- The release itself --------------------------------------------------------
grep -Eq 'gh release create[[:space:]]+"\$TAG"' <<<"$commands" \
  || fail "release.yml must cut the release with gh release create \"\$TAG\""
grep -q -- '--verify-tag' <<<"$commands" \
  || fail "gh release create must pass --verify-tag (never invent a tag)"
grep -q -- '--notes-file' <<<"$commands" \
  || fail "gh release create must pass --notes-file (the generated notes)"
grep -q -- '--config cliff.toml' <<<"$commands" \
  || fail "git-cliff must read the repository's cliff.toml explicitly (--config)"
ok "the release is cut from the signed tag with generated notes"

# --- Nothing is exit-suppressed ------------------------------------------------
release_lines="$(grep -E '(git-cliff|gh release create|sha256sum)' <<<"$commands" || true)"
if grep -Eq '\|\|[[:space:]]*(true|:)' <<<"$release_lines"; then
  fail "release.yml suppresses the exit of a release step (|| true) - it must block"
fi
grep -Eq '^[[:space:]]*continue-on-error:[[:space:]]*true' <<<"$commands" \
  && fail "release.yml sets continue-on-error: true - a failed release would look green"
ok "no release step is exit-suppressed"

# --- cliff.toml: the two properties the notes depend on ------------------------
grep -Eq '^[[:space:]]*conventional_commits[[:space:]]*=[[:space:]]*true' "$cliff" \
  || fail "cliff.toml must set conventional_commits = true"
grep -Eq '^[[:space:]]*filter_unconventional[[:space:]]*=[[:space:]]*true' "$cliff" \
  || fail "cliff.toml must set filter_unconventional = true (drops the merge commits)"
grep -Eq '\{[[:space:]]*message[[:space:]]*=[[:space:]]*"\^Merge ",[[:space:]]*skip[[:space:]]*=[[:space:]]*true' "$cliff" \
  || fail "cliff.toml must skip merge commits explicitly"
grep -Eq '^[[:space:]]*commit_parsers[[:space:]]*=' "$cliff" \
  || fail "cliff.toml must group commits by type (commit_parsers)"
ok "cliff.toml is conventional-commits only, merge commits skipped, grouped by type"

# --- Well-formedness + structure (PyYAML; loud skip when absent) --------------
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$wf" <<'PY' || fail "PyYAML structural checks failed (see above)"
import re, sys, yaml

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

assert isinstance(doc, dict), "workflow is not a YAML mapping"

# `on:` parses as the YAML 1.1 boolean True key.
trigger = doc.get(True, doc.get("on"))
assert isinstance(trigger, dict), "workflow has no trigger mapping (`on:`)"
assert set(trigger) == {"push"}, f"release.yml must trigger on push only, got {sorted(trigger)}"
push = trigger["push"] or {}
assert set(push) == {"tags"}, f"the push trigger must filter tags only, got {sorted(push)}"
assert push["tags"] == ["v*"], f"tag filter must be ['v*'], got {push['tags']!r}"

assert doc.get("permissions") == {"contents": "read"}, \
    f"top-level permissions must be contents: read, got {doc.get('permissions')!r}"

jobs = doc.get("jobs")
assert isinstance(jobs, dict) and len(jobs) == 1, \
    f"release.yml must define exactly one job, got {sorted(jobs or [])}"
name, job = next(iter(jobs.items()))

assert job.get("runs-on") == "ubuntu-latest", \
    f"job {name!r} must run on ubuntu-latest, got {job.get('runs-on')!r}"
assert job.get("permissions") == {"contents": "write"}, \
    f"job {name!r} must hold exactly contents: write, got {job.get('permissions')!r}"
assert job.get("continue-on-error") is not True, \
    f"job {name!r} must not set continue-on-error"
assert isinstance(job.get("timeout-minutes"), int), \
    f"job {name!r} must set a timeout-minutes (a hung release job burns the runner)"

steps = job.get("steps") or []
assert steps, "the release job has no steps"

checkout = [s for s in steps if str(s.get("uses") or "").startswith("actions/checkout@")]
assert len(checkout) == 1, "expected exactly one actions/checkout step"
with_ = checkout[0].get("with") or {}
assert with_.get("fetch-depth") == 0, \
    "checkout must set fetch-depth: 0 - the notes need the full history and its tags"
assert with_.get("persist-credentials") is False, \
    "checkout must set persist-credentials: false"

# A `${{ }}` inside a run: block is substituted into the script before bash sees
# it. Every value this workflow needs reaches its script through `env:` instead.
for s in steps:
    run = s.get("run")
    if run and "${{" in run:
        raise AssertionError(
            f"step {s.get('name')!r} interpolates ${{{{ }}}} inside run: - pass it via env:")

runs = "\n".join(str(s.get("run") or "") for s in steps)
assert re.search(r"sha256sum[ \t]+--check", runs), "no sha256 verification in any run: step"
assert re.search(r"gh release create[ \t]+\"\$TAG\"", runs), "no `gh release create \"$TAG\"`"
assert "--verify-tag" in runs, "gh release create must pass --verify-tag"

print(f"PyYAML: release.yml well-formed; one job {name!r} on ubuntu-latest, "
      f"{len(steps)} steps, contents: write scoped to the job")
PY
else
  if [ -n "${STRICT:-}" ]; then fail "PyYAML unavailable and STRICT=1 - release.yml structural checks not run"; fi
  echo "SKIP: PyYAML unavailable - release.yml structural checks not run"
fi

echo "PASS: release_workflow_test ($pass assertions)"
