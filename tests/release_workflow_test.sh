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
  # tests/release_workflow_check.py, not a `python3 - <<'PY'` heredoc: it keeps
  # the PyYAML checks (Python's regex dialect) out of a `.sh` file that
  # bin/check-patterns arm (8) scans for GNU-only SHELL-regex escapes. See that
  # file's header for why.
  python3 "$repo_root/tests/release_workflow_check.py" "$wf" \
    || fail "PyYAML structural checks failed (see above)"
  ok "PyYAML structural checks pass on the real release.yml"

  # --- release_workflow_check.py's own failure contract ------------------------
  # A `|| fail` around a check that never actually fails proves nothing: this
  # feeds the script a MUTATED copy of release.yml and asserts it exits non-zero,
  # so the failure path above is known to fire on a real defect, not just to be
  # unreachable dead code. mktemp dir, cleaned up on exit like
  # tests/check_patterns_test.sh's own fixture trees.
  mut_dir="$(mktemp -d "${TMPDIR:-/tmp}/release_workflow_check_test.XXXXXX")"
  trap 'rm -rf "$mut_dir"' EXIT INT TERM
  mut_wf="$mut_dir/release.yml"
  # A plain string swap, no regex: breaks the `job.get("runs-on") ==
  # "ubuntu-latest"` assertion without touching anything else in the file.
  sed 's/ubuntu-latest/ubuntu-24.04/' "$wf" > "$mut_wf"
  grep -q 'ubuntu-24.04' "$mut_wf" || fail "fixture bug: the runs-on mutation did not apply"
  if python3 "$repo_root/tests/release_workflow_check.py" "$mut_wf" >/dev/null 2>&1; then
    fail "release_workflow_check.py must fail on a mutated release.yml (runs-on changed), but it exited 0"
  fi
  ok "release_workflow_check.py fails on a mutated release.yml (runs-on changed)"

  # --- missing argv[1] ----------------------------------------------------------
  if python3 "$repo_root/tests/release_workflow_check.py" >/dev/null 2>&1; then
    fail "release_workflow_check.py must fail with no workflow path argument, but it exited 0"
  fi
  ok "release_workflow_check.py fails with no argv (IndexError on sys.argv[1])"
else
  if [ -n "${STRICT:-}" ]; then fail "PyYAML unavailable and STRICT=1 - release.yml structural checks not run"; fi
  echo "SKIP: PyYAML unavailable - release.yml structural checks not run"
fi

echo "PASS: release_workflow_test ($pass assertions)"
