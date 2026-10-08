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
and with a query: https://github.com/brunovenceslau/dotfiles/blob/main/README.md?plain=1#top

A [full reference][Ref], a [collapsed one][] and a [third setup](docs/guide.md#setup-2).
Slugs: [code span](docs/guide.md#the-_link_bin_tree-helper),
[escape](docs/guide.md#a_b-escaped), [taken](docs/guide.md#foo-1-1).
HTML: <img src="docs/guide.md" alt="x"> and <a href="docs/guide.md#tail">tail</a>.

[ref]: docs/guide.md#tail
[collapsed one]: docs/guide.md

Ignored in code: `[x](missing.md)` and:

```sh
[y](also-missing.md#nope)
```

~~~
[z](tilde-missing.md)
~~~

<!-- [c](comment-missing.md) and [d][undefined] -->

    [indented](indented-code-missing.md)

- a list item

  ```
  [w](list-fence-missing.md)
  ```

      [v](docs/guide.md#tail) is list content, so it is still checked.
EOF
  cat >"$work/r/docs/guide.md" <<'EOF'
# Guide

## Setup

## Setup

## Setup

## What `make x` does, really?

## The `_link_bin_tree` helper

## a\_b *escaped*

## Foo

## Foo

## Foo-1

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
expect_broken README.md 'See [third](docs/guide.md#setup-3).' \
  'no such anchor in docs/guide\.md: docs/guide\.md#setup-3' \
  "a heading repeated three times numbers -1 and -2, never -3"
expect_broken README.md 'See [taken](docs/guide.md#foo-2).' \
  'no such anchor in docs/guide\.md: docs/guide\.md#foo-2' \
  "a heading reading Foo-1 after two Foo headings is numbered foo-1-1, as github-slugger does"
expect_broken README.md 'See [case](docs/GUIDE.md).' \
  'no such tracked file or directory: docs/GUIDE\.md' \
  "a path that differs from the tracked one only in case fails"
expect_broken README.md 'See [nothing][missing label].' \
  'no such reference definition in this file: \[missing label\]' \
  "a reference link with no definition fails"
expect_broken README.md 'An <img src="docs/missing.png" alt="x">.' \
  'no such tracked file or directory: docs/missing\.png' \
  "an HTML src is checked"
expect_broken README.md "- item

      [u](list-content-missing.md)" \
  'list-content-missing\.md' \
  "an indented line inside a list is content, not code, and is checked"
expect_broken README.md '<!--
## Hidden
-->
See [hidden](#hidden).' \
  'no such anchor in README\.md: #hidden' \
  "a heading inside an HTML comment is not a heading"
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
want_line="$(wc -l <"$work/r/README.md" | tr -d ' ')"
run
[ "$rc" = 1 ] || fail "a link after a closed fence must be checked (exit $rc): $out"
grep -qx "README.md:$want_line: no such tracked file or directory: missing-too.md" <<<"$out" \
  || fail "the link after the fence must be reported at README.md:$want_line: $out"
if grep -q ': missing\.md$' <<<"$out"; then fail "a link inside a fence was reported: $out"; fi
ok "a fence hides its links and a closed fence stops hiding"

# Front matter is blanked, never dropped: a line number after it is exact.
new_tree
printf -- '---\ndescription: x\n---\n\n[gone](gone.md)\n' >"$work/r/docs/front.md"
git -C "$work/r" add -A
run
grep -qx 'docs/front.md:5: no such tracked file or directory: gone.md' <<<"$out" \
  || fail "a link after front matter must be reported at its own line (5): $out"
ok "front matter keeps line numbers exact"

# An unclosed fence hides the rest of the file, as GitHub renders it.
new_tree
printf '%s\n' '```' '[a](missing.md)' >>"$work/r/README.md"
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "a link after an unclosed fence is code and must be ignored (exit $rc): $out"
ok "an unclosed fence runs to the end of the file"

# A report echoes names and text from the tree: control bytes print escaped.
new_tree
printf 'See [x](a\033]52;c;aGk=\007b.md).\n' >>"$work/r/README.md"
git -C "$work/r" add -A
run
[ "$rc" = 1 ] || fail "a link holding control bytes must still be reported (exit $rc)"
case "$out" in
  *$'\033'* | *$'\007'*) fail "a raw control byte reached the report" ;;
esac
grep -qF 'a\x1b]52;c;aGk=\x07b.md' <<<"$out" || fail "the control bytes were not printed escaped: $out"
ok "control bytes in a report print as \\xHH"

# A tracked .md symlink is not read: it could point anywhere.
new_tree
printf '[broken](nowhere.md)\n' >"$work/outside.md"
ln -s "$work/outside.md" "$work/r/docs/linked.md"
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "a tracked symlink must be skipped, not followed (exit $rc): $out"
ok "a tracked Markdown symlink is skipped, not followed out of the repository"

# CRLF files: a CRLF heading is an anchor, a CR inside wrapped link text is
# harmless, and a link after CRLF front matter is reported at its own line.
new_tree
printf '## Crlf Head\r\n\r\nSetext Head\r\n===\r\n\r\nSee [wrapped\r\ntext](#crlf-head) and [s](#setext-head).\r\n' >"$work/r/docs/crlf.md"
printf -- '---\r\nx: [fm](fm-gone.md)\r\n---\r\n\r\n[gone](gone.md)\r\n' >"$work/r/docs/crlf-fm.md"
git -C "$work/r" add -A
run
[ "$rc" = 1 ] || fail "CRLF: expected exactly the front-matter case to fail (exit $rc): $out"
grep -qx 'docs/crlf-fm.md:5: no such tracked file or directory: gone.md' <<<"$out" \
  || fail "CRLF: a link after CRLF front matter must be reported at line 5: $out"
if grep -Eq 'docs/crlf\.md|fm-gone' <<<"$out"; then
  fail "CRLF: a heading anchor, the wrapped link or a link in the front matter failed: $out"
fi
ok "CRLF headings, wrapped link text and front matter behave like LF ones"

# CRLF reference definitions: a broken one is reported like its LF twin, and
# a used one satisfies its reference link (a CR once hid both).
new_tree
printf '[unused]: gone.md\r\n' >"$work/r/docs/crlf-def.md"
printf '[ref]: guide.md\r\n\r\nSee [x][ref].\r\n' >"$work/r/docs/crlf-ref.md"
git -C "$work/r" add -A
run
[ "$rc" = 1 ] || fail "CRLF refdef: expected exactly the broken definition to fail (exit $rc): $out"
grep -qx 'docs/crlf-def.md:1: no such tracked file or directory: gone.md' <<<"$out" \
  || fail "CRLF refdef: a broken CRLF definition must be reported: $out"
if grep -q 'crlf-ref' <<<"$out"; then
  fail "CRLF refdef: a CRLF definition must satisfy its reference link: $out"
fi
ok "CRLF reference definitions are checked and satisfy their links, as LF ones do"

# A closing sequence of `#` is not heading text: `## Closed ##` is #closed,
# and a heading of a long run of spaces is read in linear time (below).
new_tree
printf '## Closed ##\n\n## #\n\n[c](#closed)\n' >"$work/r/docs/atx.md"
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "an ATX closing sequence must not reach the slug (exit $rc): $out"
ok "an ATX closing sequence is dropped from the heading's id"

# An HTML comment that never closes runs to the end of the file.
new_tree
printf '<!-- open
[a](cmt-missing.md)

[b](cmt-missing-2.md)
' >"$work/r/docs/open-cmt.md"
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "an unclosed HTML comment must hide the rest of the file (exit $rc): $out"
ok "an unclosed HTML comment runs to the end of the file"

# Front matter that never closes is prose, so its links are checked.
new_tree
printf -- '---\nx: y\n[gone](gone.md)\n' >"$work/r/docs/open-fm.md"
git -C "$work/r" add -A
run
grep -qx 'docs/open-fm.md:3: no such tracked file or directory: gone.md' <<<"$out" \
  || fail "an unclosed front matter must be read as prose (exit $rc): $out"
ok "front matter that never closes is prose"

# A Unicode heading slugs to its letters; a tab-indented fence hides its
# links; a mailto: link is external and ignored; a single-quoted src is read.
new_tree
printf '## Caf\303\251 \303\234bersicht\n\n[u](#caf\303\251-\303\274bersicht) [m](mailto:nobody@example.com)\n\n\t```\n[x](tab-fence-missing.md)\n\t```\n' >"$work/r/docs/uni.md"
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "a Unicode anchor, a mailto: link and a tab-indented fence must pass (exit $rc): $out"
ok "Unicode heading slug, mailto: ignored, tab-indented fence ignored"
expect_broken README.md "An <img alt='x' src='docs/missing.png'>." \
  'no such tracked file or directory: docs/missing\.png' \
  "a single-quoted HTML src is checked"
long_name="$(printf 'x%.0s' $(seq 1 2100)).md"
expect_broken README.md "An <a href=\"docs/$long_name\">long</a>." \
  "no such tracked file or directory: docs/x{2100}\\.md" \
  "an HTML href over 2048 characters is still checked"
expect_broken README.md "$(printf 'See [z](docs/a\342\200\256b.md).')" \
  'docs/a\\u202eb\.md' \
  "a bidi override in a report prints as \\uHHHH"

# Hostile input stays near-linear: many unclosed comment openers, tag
# openers with no `>`, unclosed quotes, backtick runs of every length and
# unclosed brackets, 100 KB to 2.2 MB each, in prose and in headings (a link
# with an #anchor into each file makes the heading pass read it too). The
# previous regexes were quadratic here (measured: one 200 KB line of
# `[a](b` alone, or of `<a `, outlived 20 s, and a single 200 KB heading of
# `[` or of `[a](x` did too), while every scan now takes well under a second,
# so the 30 s bound separates the two with room for a slow runner.
# shellcheck source=tests/lib/bounded_run.sh
. "$repo_root/tests/lib/bounded_run.sh"
new_tree
python3 -I - "$work/r/docs" <<'PY'
import os, sys
d, n = sys.argv[1], 200000
shapes = {
    "h1.md": "<!-- x " * 30000,
    "h2.md": '<a title="x ' * 18000,
    "h3.md": "<img href='" * 18000,
    "h4.md": "".join("`" * k + " x " for k in range(1, 1500)),
    "h5.md": "[" * 100000,
    "h6.md": "<a " * 60000 + ">",
    "h7.md": "[a](b" * (n // 5),
    "h8.md": '[a](b "x ' * (n // 9),
    "h9.md": "[a\n" * (2 * n // 3),
    "h10.md": "<a " * (n // 3),
    "h11.md": '<a id="x ' * (n // 9),
    "h12.md": "# " + " " * n + "x",
    "h13.md": "# " + "[a](x" * (n // 5),
    "h14.md": "# " + "[" * n,
    "h15.md": "# " + "<" * (2 * n),
    "h16.md": "# " + "".join("`" * k + " x " for k in range(1, 2100)),
    "h17.md": "[a][" * (n // 4),
}
with open(os.path.join(d, "hostile-links.md"), "w") as f:
    for name, body in shapes.items():
        with open(os.path.join(d, name), "w") as g:
            g.write(body + "\n")
        f.write("[x](%s#x)\n" % name)
PY
git -C "$work/r" add -A
bounded_run 30 "$work/hostile.out" python3 -I "$gate" "$work/r" \
  || fail "hostile input: bounded_run could not turn job control on"
[ "$br_hung" = 0 ] && [ "$br_stuck" = 0 ] \
  || fail "hostile input: linkcheck outlived 30 s (hung $br_hung, stuck $br_stuck)"
[ "$br_rc" = 0 ] || [ "$br_rc" = 1 ] \
  || fail "hostile input: expected a verdict (0 or 1), got $br_rc: $(cat "$work/hostile.out")"
ok "hostile input (unclosed comments, tags, quotes, links, labels, backtick runs, brackets, in prose and headings) finishes in bounded time"

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

# A directory swapped for a symlink in the working tree (git still tracks
# the files under it) would read files from outside the checkout.
new_tree
mkdir -p "$work/elsewhere"
printf '# Guide\n\n[broken](nowhere.md)\n' >"$work/elsewhere/guide.md"
rm -rf "$work/r/docs"; ln -s "$work/elsewhere" "$work/r/docs"
run
[ "$rc" = 2 ] && grep -q 'reached through a symlink' <<<"$out" \
  || fail "a tracked file reached through a swapped-in directory symlink must exit 2, got $rc: $out"
ok "a directory swapped for a symlink in the working tree: exit 2"

echo "linkcheck_test: $pass passed"
