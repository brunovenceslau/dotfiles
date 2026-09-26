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
#   - the release title is fixed to `dotfiles $TAG`, not gh/GitHub's default
#     (the bare tag), so the title alone names the project on GitHub's global
#     feed - both of these, and the rest of the release command, by pinning
#     the release step's whole `run:` block byte for byte, the only `run:`
#     allowed to mention `gh`,
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
  && py_expected="$(python3 "$check_py" --print-expected-run && echo x)"; then
  [ "${py_expected%x}" = "$RELEASE_RUN_EXPECTED" ] \
    || fail "the pinned release run: literal drifted between release_workflow_test.sh and release_workflow_check.py"
  ok "the two copies of the pinned release run: literal are identical"
elif [ -n "${STRICT:-}" ]; then
  fail "python3 unavailable (or --print-expected-run failed) and STRICT=1 - the pinned-literal drift check not run"
else
  echo "SKIP: python3 unavailable (or --print-expected-run failed) - the pinned-literal drift check not run"
fi

# The PyYAML-free floor for the release step - the ONLY layer when PyYAML is
# missing, so it stands on its own. It reads the RAW file ($1), never the
# comment-filtered $commands (dropping comment lines first would change what a
# block holds), and does no shell parsing at all:
#   - every `run:` key must be a plain literal block (`run: |`, nothing after
#     the `|`), so each block's text is exactly the more-indented lines under
#     it, dedented by its first line's indentation (YAML's own rule) with
#     trailing blank lines clipped (what `|` does) - no folding, no escapes;
#   - `gh` as a word outside every run: block is allowed only on a YAML comment
#     line, which catches a `run:` hidden in a flow mapping or a quoted key;
#   - each step holds at most ONE `run:` key (PyYAML keeps the last of a
#     duplicate, so a gh-free second block would otherwise replace the one
#     this floor checked);
#   - exactly ONE block mentions `gh` as a word, found by content, not by the
#     step's name, so a rename cannot empty the check. A comment cannot hide a
#     second `gh` from this count; a deliberately obfuscated spelling (`g\h`,
#     `"g"h`, a `g\`-newline-`h` split) can, since bash runs each as gh. This
#     is a tripwire for accidental edits, not an adversarial boundary - review
#     and commit signing are the control there;
#   - that block equals $RELEASE_RUN_EXPECTED byte for byte. A file with no
#     final newline leaves YAML's `|` nothing to keep at EOF, so a block
#     ending there has no trailing newline (Python sees exactly that); awk
#     cannot tell a missing final newline apart, so the shell measures it with
#     `tail -c 1` and passes it in as `nonl`.
# Anything it cannot read that way fails closed. POSIX awk only (match/RLENGTH,
# index, split, ENVIRON): the macOS legs run BSD awk. On failure it prints one
# line and exits 1; the difference message matches the Python layer's, so a
# fixture can grep the same text from both.
release_run_check() {
  local nonl=0
  # `$(...)` strips a trailing newline, so a non-empty result means the last
  # byte is something else.
  if [ -n "$(tail -c 1 "$1")" ]; then nonl=1; fi
  RELEASE_RUN_EXPECTED="$RELEASE_RUN_EXPECTED" awk -v nonl="$nonl" '
    function lead(s) { match(s, /^ */); return RLENGTH }
    function isgh(s) { return s ~ /(^|[^A-Za-z0-9_])gh([^A-Za-z0-9_]|$)/ }
    function close_block() {
      if (!inblk) return
      inblk = 0
      if (hasgh) { ngh++; ghbody = body; ghseen = ghseen " [" firstgh "]" }
    }
    {
      if (inblk) {
        if ($0 ~ /^ *$/) {
          # A blank line; its spaces past the block indentation are content.
          pend = pend ((cont >= 0 && length($0) > cont) ? substr($0, cont + 1) : "") "\n"
          next
        }
        ind = lead($0)
        if (ind > key) {
          if (cont < 0) cont = ind
          if (ind < cont) { if (bad == "") bad = "line " NR " is under-indented inside a run: block"; next }
          line = substr($0, cont + 1)
          body = body pend line "\n"; pend = ""
          if (!hasgh && isgh(line)) { hasgh = 1; firstgh = line }
          next
        }
        close_block()
      }
      # A `- ` sequence entry opens a new mapping whose keys sit at the column
      # after the dash; remember which entry owns each key column, so a second
      # run: key in the SAME step is told apart from one in the next step.
      if (match($0, /^ *- +/)) item[RLENGTH] = NR
      if ($0 ~ /^ *(- +)?run:/) {
        if ($0 !~ /^ *(- +)?run: \|$/) {
          if (bad == "") bad = "line " NR " is a run: key that is not a plain literal block (run: |)"
          next
        }
        key = index($0, "run:") - 1
        if (nrun[key SUBSEP item[key]]++ && bad == "") bad = "line " NR " is a second run: key in the same step"
        inblk = 1; cont = -1; body = ""; pend = ""; hasgh = 0; firstgh = ""
        next
      }
      if (isgh($0) && $0 !~ /^ *#/ && bad == "") bad = "line " NR " mentions gh outside any run: block"
    }
    END {
      # Clip keeps the last content line break only if the file has one.
      if (inblk && nonl && pend == "") body = substr(body, 1, length(body) - 1)
      close_block()
      if (bad != "") { print bad; exit 1 }
      if (ngh != 1) { print "expected exactly one run: block mentioning gh, found " ngh ":" ghseen; exit 1 }
      want = ENVIRON["RELEASE_RUN_EXPECTED"]
      if (ghbody == want) exit 0
      ng = split(ghbody, g, "\n"); nw = split(want, w, "\n")
      m = (ng < nw) ? ng : nw
      for (k = 1; k <= m; k++) if (g[k] != w[k]) break
      print "the release step\047s run: differs from the pinned literal at line " k ": got: " \
        (k <= ng ? g[k] : "<end>") " | expected: " (k <= nw ? w[k] : "<end>")
      exit 1
    }
  ' "$1"
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
ok "the release step's run: block is exactly the pinned literal, and the only one mentioning gh"

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
have_yaml=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  have_yaml=1
fi

if [ "$have_yaml" -eq 1 ]; then
  # tests/release_workflow_check.py, not a `python3 - <<'PY'` heredoc: it keeps
  # the PyYAML checks (Python's regex dialect) out of a `.sh` file that
  # bin/check-patterns arm (8) scans for GNU-only SHELL-regex escapes. See that
  # file's header for why.
  python3 "$check_py" "$wf" || fail "PyYAML structural checks failed (see above)"
  ok "PyYAML structural checks pass on the real release.yml"

  # --- release_workflow_check.py's own failure contract ------------------------
  # A `|| fail` around a check that never fails proves nothing: a mutated
  # copy must make the script exit non-zero.
  mut_dir="$(mktemp -d "${TMPDIR:-/tmp}/release_workflow_check_test.XXXXXX")"
  trap 'rm -rf "$mut_dir"' EXIT INT TERM
  mut_wf="$mut_dir/release.yml"
  sed 's/ubuntu-latest/ubuntu-24.04/' "$wf" > "$mut_wf"
  grep -q 'ubuntu-24.04' "$mut_wf" || fail "fixture bug: the runs-on mutation did not apply"
  if python3 "$check_py" "$mut_wf" >/dev/null 2>&1; then
    fail "release_workflow_check.py must fail on a mutated release.yml (runs-on changed), but it exited 0"
  fi
  ok "release_workflow_check.py fails on a mutated release.yml (runs-on changed)"

  if python3 "$check_py" >/dev/null 2>&1; then
    fail "release_workflow_check.py must fail with no workflow path argument, but it exited 0"
  fi
  ok "release_workflow_check.py fails with no argv (IndexError on sys.argv[1])"
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
    if out="$(python3 "$check_py" "$mut_file" 2>&1)"; then
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
    out="$(python3 "$check_py" "$mut_file" 2>&1)" \
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

mutate extra-gh 's|^\( *\)\(echo "\$RUNNER_TEMP/bin" >> "\$GITHUB_PATH"\)$|\1\2\
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
  if out="$(python3 "$check_py" "$mut_dir/col0.yml" 2>&1)"; then
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
