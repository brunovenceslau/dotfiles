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
# legitimate `\s` there would read as a false positive. This script uses `\b`
# in the release-step selector below - exactly the kind of edit this file's
# existence anticipates: it needs no marker or exemption here, unlike in the
# shell surface itself.
#
# Kept byte-for-byte in behaviour with the former heredoc for the checks it
# still shares with it (same argv contract: sys.argv[1] is the workflow path;
# same stdout summary line on success). The release command itself is now
# pinned as a whole `run:` block - see EXPECTED_RUN below.
import re, sys

# The release step's ENTIRE `run:` block, byte for byte, trailing newline
# included - not a parse of the gh command inside it. Rounds 2 to 4 of the
# ship gate each found a new bypass in a parser that approximated shell
# (comment stripping, continuation joining, quoting); an exact literal has no
# shell semantics to approximate. Any change to the release command, its
# comments or its whitespace MUST edit this literal in the same commit - that
# edit is the review point, on purpose. tests/release_workflow_test.sh holds a
# second copy for its PyYAML-free floor and fails if the two ever differ.
EXPECTED_RUN = """\
set -euo pipefail
# --verify-tag: refuse to invent a tag. The release can only ever
# describe the signed tag that triggered this run.
# --title: gh/GitHub's default (the bare tag, e.g. "v0.2.0") reads as
# version noise on GitHub's global releases feed; "dotfiles $TAG"
# names the project inline so the title alone identifies what
# shipped.
gh release create "$TAG" --verify-tag --title "dotfiles $TAG" --notes-file "$RUNNER_TEMP/notes.md"
"""

# Lets the shell test compare its copy of the literal against this one. Before
# the yaml import on purpose: the comparison needs no PyYAML.
if sys.argv[1:] == ["--print-expected-run"]:
    sys.stdout.write(EXPECTED_RUN)
    sys.exit(0)

import yaml

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

# The key sets of the document and of the job are pinned whole, not screened
# for known-bad keys: a workflow- or job-level `env:` reaches the release step
# with the step untouched (GH_HOST, GH_ENTERPRISE_TOKEN or a proxy send the
# token elsewhere), `defaults:` swaps the shell that runs the pinned block, and
# `if:`, `container:` and the rest change where or whether it runs. A key this
# workflow does not use today has to be argued for here. `on` parses as True.
TOP_KEYS = ["jobs", "name", "on", "permissions"]
top_keys = sorted("on" if k is True else str(k) for k in doc)
assert top_keys == TOP_KEYS, \
    f"release.yml's top-level keys must be exactly {TOP_KEYS}, got {top_keys}"

jobs = doc.get("jobs")
assert isinstance(jobs, dict) and len(jobs) == 1, \
    f"release.yml must define exactly one job, got {sorted(jobs or [])}"
name, job = next(iter(jobs.items()))

JOB_KEYS = ["name", "permissions", "runs-on", "steps", "timeout-minutes"]
assert isinstance(job, dict) and sorted(job) == JOB_KEYS, \
    f"job {name!r} keys must be exactly {JOB_KEYS}, got {sorted(job or [])}"

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

# The SET of actions is pinned, not just their shape: a GitHub-owned, SHA-pinned
# action (actions/github-script) can be handed the token and never spells `gh`,
# so the one-gh-step rule below never sees it. Exactly the checkout, today.
uses = [str(s["uses"]) for s in steps if "uses" in s]
ACTIONS = ["actions/checkout"]
assert [u.split("@", 1)[0] for u in uses] == ACTIONS, \
    f"the workflow's actions must be exactly {ACTIONS}, got {[u.split('@', 1)[0] for u in uses]}"
for u in uses:
    assert re.fullmatch(r"[^@]+@[0-9a-f]{40}", u), \
        f"every action must be pinned to a 40-hex commit SHA, got {u!r}"

# Cross-step channels, banned outright. A line written to $GITHUB_ENV becomes
# env for every later step, the release step included (the upper-case name
# dodges the gh count). A directory written to $GITHUB_PATH comes before
# /usr/bin in every later step, so a `gh` planted there would run ahead of the
# real one in the release step, holding the token - which is why release.yml
# calls git-cliff by its absolute path instead. Every string in the step is
# read, keys included, not only its run: - a `shell:` template can write
# $GITHUB_ENV too - and raw, so a comment cannot hide a mention. This is a
# tripwire for accidental edits, not an adversarial boundary: an earlier step
# can still plant a `gh` without $GITHUB_PATH (a user-writable PATH
# directory, sudo into /usr/bin, ~/.config/gh); review and commit signing are
# the control there.
def strings(x):
    if isinstance(x, dict):
        for k, v in x.items():
            yield str(k)
            yield from strings(v)
    elif isinstance(x, list):
        for v in x:
            yield from strings(v)
    elif x is not None:
        yield str(x)

# GIT_CLIFF__ joins them: a GIT_CLIFF__* variable overrides any cliff.toml
# setting, postprocessors included, and the notes step's pinned env does not
# stop an `export GIT_CLIFF__...` inside its own run: text.
CHANNELS = {
    "GITHUB_ENV": "it reaches the release step",
    "GITHUB_PATH": "it reaches the release step",
    "GIT_CLIFF__": "it overrides cliff.toml",
}
for s in steps:
    text = "\n".join(strings(s))
    for var, why in CHANNELS.items():
        assert var not in text, \
            f"step {s.get('name')!r} mentions {var} - {why}"

# git-cliff by its absolute path, exactly twice (the two branches of the notes
# step), never by a bare name that a PATH entry could resolve.
cliff_lines = [ln.strip() for s in steps for ln in str(s.get("run") or "").split("\n")]
bare = [ln for ln in cliff_lines if re.match(r"git-cliff( |$)", ln)]
assert not bare, f"git-cliff is called by a bare name - call \"$RUNNER_TEMP/bin/git-cliff\": {bare[0]}"
n_abs = sum(1 for ln in cliff_lines if ln.startswith('"$RUNNER_TEMP/bin/git-cliff" '))
assert n_abs == 2, \
    f"expected exactly 2 git-cliff calls by absolute path (\"$RUNNER_TEMP/bin/git-cliff\" ...), found {n_abs}"

# The step that runs git-cliff holds only name, env and run, and its env is
# exactly TAG: a GIT_CLIFF__* variable overrides any cliff.toml setting,
# postprocessors (and their replace_command) included, so the cliff.toml check
# in tests/release_workflow_test.sh would be checking a file git-cliff no
# longer obeys. The floor pins the same step as NOTES_STEP_EXPECTED.
# A call is a run: line that STARTS with the absolute path, the same test as
# the floor's and the n_abs count above: a mention elsewhere on a line
# (`test -x "$RUNNER_TEMP/bin/git-cliff" || exit 1`) is not a call.
cliff_steps = [s for s in steps
               if any(ln.strip().startswith('"$RUNNER_TEMP/bin/git-cliff" ')
                      for ln in str(s.get("run") or "").split("\n"))]
assert len(cliff_steps) == 1, \
    f"expected git-cliff to run from exactly one step, found {len(cliff_steps)}"
notes = cliff_steps[0]
assert set(notes) == {"name", "env", "run"}, \
    f"the notes step must hold only name, env and run, got {sorted(notes)}"
assert notes["env"] == {"TAG": "${{ github.ref_name }}"}, \
    f"the notes step's env must be exactly TAG, got {notes['env']!r}"

# A `${{ }}` inside a run: block is substituted into the script before bash sees
# it. Every value this workflow needs reaches its script through `env:` instead.
for s in steps:
    run = s.get("run")
    if run and "${{" in run:
        raise AssertionError(
            f"step {s.get('name')!r} interpolates ${{{{ }}}} inside run: - pass it via env:")

runs = "\n".join(str(s.get("run") or "") for s in steps)

# Strip `#...` comments per line before looking for `sha256sum --check`, so a
# comment cannot stand in for the real flag. `(^|[ \t]+)#`, not just
# `[ \t]+#`: PyYAML dedents a `run: |` block, so a comment written at the same
# indentation as its sibling commands lands at column 0 (the R1 fixture in
# tests/release_workflow_test.sh).
runs_nc = "\n".join(re.sub(r"(^|[ \t]+)#.*$", "", ln) for ln in runs.split("\n"))
assert re.search(r"sha256sum[ \t]+--check", runs_nc), "no sha256 verification in any run: step"

# The release step, found by STRUCTURE, never by its name (a rename must not
# empty the check): across every job and every step, exactly ONE step's raw
# `run:` text mentions `gh` as a word. Raw on purpose - no comment stripping,
# no shell parsing - so a comment cannot hide a second `gh` from this count.
# A deliberately obfuscated spelling still can (`g\h`, `"g"h`, a
# `g\`-newline-`h` split: bash runs each as gh): this is a tripwire for
# accidental edits, not an adversarial boundary - review and commit signing
# are the control there. Measured on the real workflow: `gh` appears in no
# other step's run: (the two other mentions in release.yml are YAML comments
# outside any run: block), so the rule costs nothing today and a legitimate
# future `gh` elsewhere has to be argued for here.
all_steps = [s for j in jobs.values() for s in ((j or {}).get("steps") or [])]
gh_steps = [s for s in all_steps if re.search(r"\bgh\b", str(s.get("run") or ""))]
assert len(gh_steps) == 1, \
    f"expected exactly one step whose run: mentions gh, found {len(gh_steps)}: " \
    f"{[s.get('name') for s in gh_steps]}"
release_step = gh_steps[0]

actual_run = release_step.get("run")
if actual_run != EXPECTED_RUN:
    got = str(actual_run).split("\n")
    want = EXPECTED_RUN.split("\n")
    k = next((i for i in range(min(len(got), len(want))) if got[i] != want[i]),
             min(len(got), len(want)))
    raise AssertionError(
        f"the release step's run: differs from the pinned literal at line {k + 1}: "
        f"got: {got[k] if k < len(got) else '<end>'} | "
        f"expected: {want[k] if k < len(want) else '<end>'}")

# The run: literal pins the argv; the step's env pins where it points. GH_REPO
# or GH_HOST set here would send the token-bearing gh call elsewhere with the
# run: block untouched. The key set excludes `shell:` (another interpreter for
# the pinned text), `working-directory:`, `if:` and `continue-on-error:` (a
# skipped or failed release that reads green).
assert set(release_step) == {"name", "env", "run"}, \
    f"the release step must hold only name, env and run, got {sorted(release_step)}"
assert release_step["env"] == {
    "GH_TOKEN": "${{ github.token }}",
    "GH_REPO": "${{ github.repository }}",
    "TAG": "${{ github.ref_name }}",
}, f"the release step's env changed: {release_step['env']!r}"

# The release step's env above is the only place a GH_* key may sit: gh reads
# GH_HOST, GH_REPO, GH_ENTERPRISE_TOKEN and the rest from its environment.
# Workflow- and job-level env are already excluded by the key pins; this
# covers every other step's env and with:, matching the PyYAML-free floor,
# which rejects a GH_* key anywhere outside the release step's pinned env.
for s in all_steps:
    for field in ("env", "with"):
        if s is release_step and field == "env":
            continue
        m = s.get(field)
        gh_keys = sorted(str(k) for k in (m if isinstance(m, dict) else {}) if str(k).startswith("GH_"))
        assert not gh_keys, \
            f"step {s.get('name')!r} sets {gh_keys} in its {field}: - a GH_* key " \
            f"belongs only in the release step's env"

print(f"PyYAML: release.yml well-formed; one job {name!r} on ubuntu-latest, "
      f"{len(steps)} steps, contents: write scoped to the job")
