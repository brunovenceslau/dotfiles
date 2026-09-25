# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# PyYAML structural checks for .github/workflows/release.yml, called from
# tests/release_workflow_test.sh as `python3 tests/release_workflow_check.py
# "$wf"`. A SEPARATE FILE, not a `python3 - <<'PY'` heredoc, because
# bin/check-patterns arm (8) scans the shell surface (tests/ included) BY
# CONTENT for GNU-only regex escapes (`\s \w \b`, BRE `\|`) and has exactly
# one content-independent LANGUAGE exemption for that, scoped to tests/ ONLY:
# a fixed `*.py` extension filter, never a marker comment or a parse of what a
# file contains (see docs/development.md, arm 8 - the arm's other two
# exclusions, the pinned plugins dir and the script's own name, are unrelated
# path exclusions, not language exemptions). Those escapes are perfectly
# portable inside a Python `re` pattern; a shell heredoc puts Python source
# inside a `.sh` file, which the extension filter cannot see past, so a
# legitimate `\s` there would read as a false positive. This script does not
# use one today (its regexes use `[ \t]+`, kept verbatim from the former
# heredoc) - it lives here so a future edit that legitimately needs one, in
# THIS file, needs no marker or exemption of its own.
#
# Kept byte-for-byte in behaviour with the former heredoc: same PyYAML
# assertions, same failure messages, same argv contract (sys.argv[1] is the
# workflow path), same stdout summary line on success.
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
