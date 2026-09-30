#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Tests for the `make linkcheck` gate (tests/linkcheck.py). Two things can rot:
# the WIRING (a gate that is not a local-ci prerequisite runs nowhere, and one
# that skips under STRICT=1 greens a check CI never ran), and the RESOLVER,
# whose every rule is exercised here against a hermetic git fixture in BOTH
# directions - a good tree passes, and each kind of breakage fails with a
# report naming its file and line. The fixture is `git add`ed, never
# committed: the gate reads the index (`git ls-files --cached`), so no author
# identity or signing config is involved.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mk="$repo_root/Makefile"
wf="$repo_root/.github/workflows/ci.yml"
gate="$repo_root/tests/linkcheck.py"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ok: $1"; }

# --- Wiring ------------------------------------------------------------------
grep -Eq '^linkcheck:' "$mk" || fail "Makefile has no 'linkcheck' target"
recipe="$(awk '/^linkcheck:/{p=1; next} /^[^\t]/{p=0} p' "$mk")"
[ -n "$recipe" ] || fail "could not read the 'linkcheck' recipe out of the Makefile"
grep -qF 'python3 -I tests/linkcheck.py' <<<"$recipe" \
  || fail "the 'linkcheck' recipe must run 'python3 -I tests/linkcheck.py'"
grep -qF '$(GIT_ENV_SCRUB)' <<<"$recipe" \
  || fail "the 'linkcheck' recipe must unset git's local env vars first (\$(GIT_ENV_SCRUB))"
grep -q 'STRICT' <<<"$recipe" && grep -q 'exit 1' <<<"$recipe" \
  || fail "the 'linkcheck' recipe must fail closed under STRICT=1 when python3 is absent"
ok "Makefile's 'linkcheck' target runs the gate, scrubs git's env and honours STRICT"
grep -qw linkcheck <<<"$(grep -E '^local-ci:' "$mk")" \
  || fail "linkcheck must be a local-ci prerequisite (it is a blocking gate)"
ok "linkcheck is a local-ci prerequisite"
if grep -q 'linkcheck\.py' "$wf"; then
  fail "ci.yml calls tests/linkcheck.py directly - gate logic goes through 'make local-ci'"
fi
ok "ci.yml reaches the gate only through make"

if ! command -v python3 >/dev/null 2>&1; then
  [ -z "${STRICT:-}" ] || fail "python3 not installed and STRICT=1 - failing closed"
  echo "  SKIP: python3 not installed - the resolver cases need it (set STRICT=1 to fail)"
  echo "linkcheck_test: $pass passed (resolver cases skipped)"
  exit 0
fi

# --- Resolver, against a hermetic fixture --------------------------------------
work="$(mktemp -d "${TMPDIR:-/tmp}/linkcheck-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# new_tree - a fresh fixture that passes: every link form the gate reads, each
# pointing at something real, plus links that only LOOK broken because they
# sit in code (a fenced block, an inline span) and must be ignored.
new_tree() {
  rm -rf "$work/r"
  mkdir -p "$work/r/docs" "$work/r/.github/ISSUE_TEMPLATE"
  git -C "$work/r" init -q
  cat >"$work/r/README.md" <<'EOF'
# Top

See [the guide](docs/guide.md), [its setup](docs/guide.md#setup), the
[second setup](docs/guide.md#setup-1), [the docs dir](docs/) and
[a heading with `code`, punctuation and CAPS](docs/guide.md#what-make-x-does-really).
A link whose text wraps: [the guide's
tail](docs/guide.md#tail). [Self](#top) and [explicit](docs/guide.md#pinned).
An external [site](https://example.com/nope) is never fetched.
Absolute: https://github.com/brunovenceslau/dotfiles/blob/main/docs/guide.md#tail

[ref]: docs/guide.md#tail

Ignored in code: `[x](missing.md)` and:

```sh
[y](also-missing.md#nope)
```
EOF
  cat >"$work/r/docs/guide.md" <<'EOF'
# Guide

## Setup

## Setup

## What `make x` does, really?

<a id="pinned"></a>

## Tail

Back to [the top](../README.md#top).
EOF
  cat >"$work/r/.github/ISSUE_TEMPLATE/bug.yml" <<'EOF'
body:
  - type: markdown
    attributes:
      value: Read https://github.com/brunovenceslau/dotfiles/blob/main/docs/guide.md#setup first.
EOF
  git -C "$work/r" add -A
}

# run - the gate over the fixture; sets rc and out.
run() { rc=0; out="$(python3 -I "$gate" "$work/r" 2>&1)" || rc=$?; }

# expect_broken FILE CONTENT PATTERN WHY - append CONTENT to FILE in a fresh
# tree and require exit 1 with a report line matching PATTERN.
expect_broken() {
  new_tree
  printf '%s\n' "$2" >>"$work/r/$1"
  git -C "$work/r" add -A
  run
  [ "$rc" = 1 ] || fail "$4: expected exit 1, got $rc: $out"
  grep -Eq -- "$3" <<<"$out" || fail "$4: report does not match /$3/: $out"
  ok "$4"
}

new_tree; run
[ "$rc" = 0 ] || fail "a good tree must pass (exit $rc): $out"
grep -q 'linkcheck: 3 files, 0 broken links' <<<"$out" \
  || fail "summary line missing or wrong: $out"
ok "a good tree passes: relative, anchor, duplicate, slug, wrapped, reference, explicit, absolute self links; code ignored"

expect_broken README.md 'See [gone](docs/gone.md).' \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone\.md$' \
  "a broken relative link fails and names its file and line"
expect_broken README.md 'See [nope](docs/guide.md#no-such-heading).' \
  'no such anchor in docs/guide\.md: docs/guide\.md#no-such-heading' \
  "a broken anchor fails"
expect_broken README.md 'See [third](docs/guide.md#setup-2).' \
  'no such anchor in docs/guide\.md: docs/guide\.md#setup-2' \
  "a duplicate heading numbers -1 only as far as it repeats (-2 fails)"
expect_broken README.md 'See [self](#Top).' \
  'no such anchor in README\.md: #Top' \
  "an anchor is compared exactly: GitHub's ids are lowercase"
expect_broken README.md 'See [up](../outside.md).' \
  'leaves the repository: \.\./outside\.md' \
  "a link out of the repository fails"
expect_broken README.md 'See [root](/docs/guide.md).' \
  'absolute path' \
  "a root-absolute path fails: GitHub resolves it against the host"
expect_broken .github/ISSUE_TEMPLATE/bug.yml '      value2: https://github.com/brunovenceslau/dotfiles/blob/main/docs/guide.md#gone' \
  '^\.github/ISSUE_TEMPLATE/bug\.yml:[0-9]+: no such anchor' \
  "an absolute link back into the repository is resolved in the issue-form YAML too"

# An untracked file resolves on disk but not on GitHub.
new_tree
printf '%s\n' 'See [local](docs/notes.local.md).' >>"$work/r/README.md"
git -C "$work/r" add -A
printf 'x\n' >"$work/r/docs/notes.local.md"
run
[ "$rc" = 1 ] && grep -q 'no such tracked file or directory: docs/notes.local.md' <<<"$out" \
  || fail "a link to an untracked file must fail (exit $rc): $out"
ok "a link to an untracked file fails: GitHub renders the tracked tree"

# The same missing target inside a fence that was never closed stays ignored,
# and one after a CLOSED fence is checked again.
new_tree
printf '%s\n' '```' '[a](missing.md)' '```' '[b](missing-too.md)' >>"$work/r/README.md"
git -C "$work/r" add -A
run
[ "$rc" = 1 ] || fail "a link after a closed fence must be checked (exit $rc): $out"
grep -q 'missing-too\.md' <<<"$out" || fail "the link after the fence was not reported: $out"
if grep -q ': missing\.md$' <<<"$out"; then fail "a link inside a fence was reported: $out"; fi
ok "a fence hides its links and a closed fence stops hiding"

# --- Fails closed ---------------------------------------------------------------
rm -rf "$work/plain"; mkdir -p "$work/plain"
rc=0; out="$(python3 -I "$gate" "$work/plain" 2>&1)" || rc=$?
[ "$rc" = 2 ] || fail "a directory outside any git checkout must exit 2, got $rc: $out"
ok "not a git checkout: exit 2"

new_tree
mkdir -p "$work/r/sub"; printf '# x\n' >"$work/r/sub/x.md"; git -C "$work/r" add -A
rc=0; out="$(python3 -I "$gate" "$work/r/sub" 2>&1)" || rc=$?
[ "$rc" = 2 ] || fail "a subdirectory of a checkout must exit 2 (a subset scan), got $rc: $out"
ok "a subdirectory instead of the toplevel: exit 2"

new_tree
printf '\377\376 not utf-8\n' >>"$work/r/docs/guide.md"; git -C "$work/r" add -A
run
[ "$rc" = 2 ] && grep -q 'not UTF-8' <<<"$out" \
  || fail "a non-UTF-8 file must exit 2, got $rc: $out"
ok "a non-UTF-8 file: exit 2"

new_tree
rm "$work/r/docs/guide.md"
run
[ "$rc" = 2 ] || fail "a tracked file missing from the working tree must exit 2, got $rc: $out"
ok "a tracked file deleted from the working tree: exit 2"

echo "linkcheck_test: $pass passed"
