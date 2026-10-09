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

# A heading holding a link renders as the link's text alone, whatever its
# destination holds: balanced parentheses (a Wikipedia URL) nested up to 3
# levels, an escaped paren, an angle-bracket form with a space, a quoted or
# parenthesized title. A destination with a bare space, a backslash before a
# non-punctuation character, or a 4th nesting level is not matched, so its
# text stays literal (the depth limit is pinned on purpose). An image adds no
# text to the rendered heading, so its id starts with the hyphen the space
# beside it leaves (html-pipeline's TocFilter). `## Odd (text` is a regression
# guard only: it passed before the fix.
# External (https) destinations keep the unrelated link pass out of the way.
# Expected ids follow github-slugger: lowercase, punctuation such as `()`
# dropped, `_` kept, each space a `-`.
new_tree
cat >"$work/r/docs/paren.md" <<'MD'
## ![i](https://e.com/a_(b)) [Foo](https://e.com/c_(d)) now

## X [Foo](https://e.com/a_((b))) y

## Z [Foo](https://e.com/a_(((b)))) w

## E [Foo](https://e.com/a\(b) v

## A [Foo](<https://e.com/a b> "t") [Bar](https://e.com/c 'ttl') [Baz](https://e.com/d (p)) u

## S [a](b c) t

## B [a](https://e.com/x\ y) t

## D [Foo](https://e.com/a_((((b))))) q

## Odd (text

## ![i](https://e.com/u "t") Foo

[1](#-foo-now) [2](#x-foo-y) [3](#z-foo-w) [4](#e-foo-v) [5](#a-foo-bar-baz-u)
[6](#s-ab-c-t) [7](#b-ahttpsecomx-y-t) [8](#d-foohttpsecomab-q) [9](#odd-text) [10](#-foo)
MD
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "a heading link must slug to its text, whatever its destination holds (exit $rc): $out"
ok "a heading link slugs to its text: nesting to 3 levels, escaped paren, angle form, titles, image; a spaced or 4-deep destination stays literal"
expect_broken README.md "An <img alt='x' src='docs/missing.png'>." \
  'no such tracked file or directory: docs/missing\.png' \
  "a single-quoted HTML src is checked"
# A body link's destination follows the heading's rule: balanced parentheses
# nested up to 3 levels, an escaped paren (read unescaped, in a definition
# too), and the `<...>` form, which may hold a space or an escaped `>`. A
# bare destination never starts with `<`, so `[a](<b)` is literal text, in a
# heading too.
new_tree
printf '# Paren\n' >"$work/r/docs/a_(b).md"
printf '# Gt\n' >"$work/r/docs/a>b.md"
printf '# Deep\n' >"$work/r/docs/z_(((w))).md"
printf '# Space\n' >"$work/r/docs/sp ace.md"
cat >"$work/r/docs/body-paren.md" <<'MD'
## L [a](<b) t

[1](a_(b).md) [2](a_(b).md#paren) [3](a_\(b\).md) [4](<a_(b).md>)
[5](z_(((w))).md#deep) [6](<sp ace.md>) [7](<sp ace.md#space>) [8](#l-ab-t)
[10][r]

[r]: a_\(b\).md#paren
MD
# \134 is the backslash: check-patterns refuses a literal backslash-`>` in
# shell, since BSD and GNU grep read it differently.
printf '[9](<a\134>b.md#gt>)\n' >>"$work/r/docs/body-paren.md"
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "a body destination with parentheses, an escape or <...> must resolve (exit $rc): $out"
ok "a body link resolves nested parentheses, escapes (in a definition too) and <...> with an escaped '>'; [a](<b) is literal"
expect_broken README.md 'See [x](docs/gone_(b).md).' \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone_\(b\)\.md$' \
  "a broken body destination with parentheses is reported whole"
expect_broken README.md 'See [x](<docs/gone file.md>).' \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone file\.md$' \
  "a broken <...> destination holding a space is checked"
expect_broken README.md 'See [x](docs/gone\(1\).md).' \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone\\\(1\\\)\.md$' \
  "a broken destination is reported as written, escapes and all"
expect_broken README.md "$(printf 'See [x](<docs/gone\134>b.md>).')" \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone.>b\.md$' \
  "a broken <...> destination holding an escaped '>' is checked"
# A title never crosses a blank line (CommonMark), so this is text, not a link.
new_tree
printf '[x](docs/gone.md "a\n\nb")\n' >"$work/r/docs/para-title.md"
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "a title across a blank line must not make a link (exit $rc): $out"
ok "a title across a blank line is text, not a link"
# Forms that hid a link before: a single-quoted or parenthesized title, a
# `>` inside a quoted HTML attribute before the href, an escaped `]` in a
# reference label (full, collapsed and in the definition), and a `<...>`
# definition holding a space. Each resolves here, and each is reported
# when broken (below).
new_tree
printf '# Space\n' >"$work/r/docs/sp ace.md"
cat >"$work/r/docs/forms.md" <<'MD'
# Forms

[1](guide.md 'single') [2](guide.md (paren)) [3](guide.md "double")
<a title="x>y" href="guide.md#tail">4</a> <img alt='a>b' src="guide.md">
A [full][a\]b], a [c\]d][] and a [spaced one][sp].

[a\]b]: guide.md#setup
[c\]d]: #forms
[sp]: <sp ace.md> "title"
MD
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "titles, a quoted '>' before an href, escaped label brackets and a <...> definition must resolve (exit $rc): $out"
ok "single-quoted and parenthesized titles, a quoted '>' in a tag, an escaped ']' in a label and a spaced <...> definition resolve"
expect_broken README.md "See [x](docs/gone.md 'title')." \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone\.md$' \
  "a link with a single-quoted title is checked"
expect_broken README.md 'See [x](docs/gone.md (title)).' \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone\.md$' \
  "a link with a parenthesized title is checked"
expect_broken README.md '<a title="x>y" href="docs/gone.md">x</a>' \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone\.md$' \
  "an href after a quoted attribute holding '>' is checked"
expect_broken README.md "<img alt='a>b' src='docs/gone.png'>" \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone\.png$' \
  "a single-quoted src after a quoted attribute holding '>' is checked"
expect_broken README.md 'See [x][a\]b].

[a\]b]: docs/gone.md' \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone\.md$' \
  "a definition whose label holds an escaped ']' is checked"
expect_broken README.md 'See [x][no\]def].' \
  'no such reference definition in this file: \[no\\\]def\]' \
  "a full reference whose label holds an escaped ']' needs a definition"
expect_broken README.md 'See [no\]def][].' \
  'no such reference definition in this file: \[no\\\]def\]' \
  "a collapsed reference whose text holds an escaped ']' needs a definition"
expect_broken README.md '[sp]: <docs/gone file.md>' \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone file\.md$' \
  "a <...> definition holding a space is checked whole"
# An open tag never crosses a blank line, and an opener that is no tag is
# text, so a tag inside it is still found.
expect_broken README.md "<a t='x <a href=\"docs/gone.md\">y</a>" \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone\.md$' \
  "a tag after an opener whose quote never closes is checked"
expect_broken README.md 'A stray <a title="oops in prose, then <a href="docs/gone.md">t</a> later.' \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone\.md$' \
  "a tag inside the would-be quoted value of a stray opener is checked"
new_tree
printf '<a href="docs/gone.md"\n\n>x</a>\n' >"$work/r/docs/not-tags.md"
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "a tag across a blank line is text (exit $rc): $out"
ok "a tag across a blank line is text, not a tag"
# GitHub's HTML5 parser renders what CommonMark's inline grammar refuses, in
# an HTML block: an attribute run onto a quoted value, a name opening with a
# digit. Those links are live, so they are checked.
expect_broken README.md '<div>
<a title="x"y href="docs/gone-block.md">x</a>
</div>' \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone-block\.md$' \
  "an href after an attribute run onto a quoted value is checked"
expect_broken README.md '<div>
<a 1x href="docs/gone-block2.md">x</a>
</div>' \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone-block2\.md$' \
  "an href after an attribute name opening with a digit is checked"
expect_broken README.md '<a href=docs/gone.md>x</a>' \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone\.md$' \
  "a bare (unquoted) href is checked"
expect_broken README.md '<IMG SRC="docs/gone.png">' \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone\.png$' \
  "an uppercase tag and attribute are checked"
new_tree
printf 'x\n<a\nhref="docs/gone.md">y</a>\n' >"$work/r/docs/wrapped-tag.md"
git -C "$work/r" add -A
run
grep -qx 'docs/wrapped-tag.md:3: no such tracked file or directory: docs/gone.md' <<<"$out" \
  || fail "an href on a tag's continuation line must be reported at its own line (3): $out"
ok "an href on a tag's continuation line is reported at its own line"
# An explicit anchor is any tag's id or an <a>'s name, read by the same tag
# reader: after a quoted '>', single-quoted, or on a continuation line.
new_tree
printf '%s\n' '<a title=">" id="x1"></a> <a id='"'x2'"'></a> <a' 'name="x3"></a>' '' \
  '[1](#x1) [2](#x2) [3](#x3)' >"$work/r/docs/ids.md"
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "an id after a quoted '>', a single-quoted id and an id on a continuation line are anchors (exit $rc): $out"
ok "an id after a quoted '>', a single-quoted id and a name on a continuation line are anchors"
# A label is at most 999 characters (CommonMark 4.7): one of 999 defines,
# one of 1000 does not.
new_tree
l999="$(printf 'y%.0s' $(seq 1 999))"
printf '[a][%s]\n\n[%s]: guide.md\n\n[%sy]: gone.md\n' "$l999" "$l999" "$l999" \
  >"$work/r/docs/labels.md"
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "a 999-character label must define and a 1000-character one must not (exit $rc): $out"
ok "a 999-character label defines; a 1000-character one is not a definition"
# A definition (CommonMark 4.7) may put its destination on the next line,
# and is no definition when anything but a title follows the destination.
expect_broken README.md '[nl]:
  docs/gone.md' \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone\.md$' \
  "a definition with its destination on the next line is checked"
expect_broken README.md 'See [x][junk].

[junk]: docs/guide.md junk' \
  'no such reference definition in this file: \[junk\]' \
  "a definition with text after its destination is not a definition"
new_tree
printf 'See [x][a\n\nb] there.\n' >"$work/r/docs/label-para.md"
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "a reference label across a blank line is text (exit $rc): $out"
ok "a reference label across a blank line is text, not a reference"
# Destinations hold what CommonMark keeps: a non-ASCII space (U+00A0, U+2028)
# is part of the destination, a blank line ends the link, a reference is
# decoded (`&amp;`), and a backslash before a letter is literal.
expect_broken README.md "$(printf 'See [x](docs/gone\302\240x.md).')" \
  "$(printf '^README\\.md:[0-9]+: no such tracked file or directory: docs/gone\302\240x\\.md$')" \
  "a destination holding U+00A0 is checked whole"
expect_broken README.md "$(printf 'See [x](docs/gone\342\200\250x.md).')" \
  'no such tracked file or directory: docs/gone\\u2028x\.md$' \
  "a destination holding U+2028 is checked whole, and the separator prints escaped"
new_tree
printf '[q](\n\ngone-para.md)\n' >"$work/r/docs/para-dest.md"
printf '# Amp\n' >"$work/r/docs/a&b.md"
bs="$(printf '\134')"
printf '# Bs\n' >"$work/r/docs/a${bs}b.md"
printf '[1](a&amp;b.md#amp) [2](a&#38;b.md) <a href="a&amp;b.md">3</a> [4](a%sb.md#bs)\n' "$bs" \
  >"$work/r/docs/decode.md"
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "a blank line ends a link; references decode; a backslash before a letter is literal (exit $rc): $out"
ok "a blank line ends a link, '&amp;' and '&#38;' decode, and a backslash before a letter is literal"
# References decode the CommonMark way: a name must match exactly, a
# numeric reference is its code point (a control included), and an escaped
# `&` keeps the reference literal, in one pass.
new_tree
printf '# Ampx\n' >"$work/r/docs/a&ampx;b.md"
printf '# Esc\n' >"$work/r/docs/c$(printf '\033')d.md"
printf '# Lit\n' >"$work/r/docs/a&amp;b.md"
printf '[1](a&ampx;b.md#ampx) [2](c&#27;d.md#esc) [3](a\134&amp;b.md#lit)\n' \
  >"$work/r/docs/refs.md"
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "'&ampx;' must stay literal, '&#27;' must be ESC, and '\\&amp;' must stay literal (exit $rc): $out"
ok "'&ampx;' stays literal, '&#27;' decodes to its control, and an escaped '&amp;' stays literal"
expect_broken README.md "$(printf 'See [x](docs/gone\363\240\201\201.md).')" \
  'docs/gone\\U000e0041\.md$' \
  "a tag character in a report prints as \\UHHHHHHHH"
expect_broken README.md '<img id="imgid" src="docs/guide.md">

See [x](#imgid).' \
  'no such anchor in README\.md: #imgid' \
  "an <img> id is not an anchor: only an <a> id or name is"
expect_broken README.md "$(printf 'See [x](docs/gone\342\201\240.md).')" \
  'docs/gone\\u2060\.md$' \
  "a word joiner in a report prints as \\uHHHH"
# An opening bracket after an even run of backslashes opens a link; after an
# odd run it is escaped.
new_tree
printf '%s\n' 'A \\[a](docs/gone-even.md) and \[b](docs/gone-odd.md).' >"$work/r/docs/bs-run.md"
git -C "$work/r" add -A
run
[ "$rc" = 1 ] && grep -q 'gone-even\.md' <<<"$out" && ! grep -q 'gone-odd' <<<"$out" \
  || fail "an even run of backslashes before [ must leave a link, an odd run escape it (exit $rc): $out"
ok "an even run of backslashes before [ leaves a link; an odd run escapes it"
# A title may hold its own delimiter escaped, in each of its three forms.
new_tree
printf '%s\n' '[1](docs/gone.md "t \" q") [2](docs/gone-2.md '"'t \\' q'"') [3](docs/gone-3.md (t \) q))' \
  >"$work/r/docs/esc-title.md"
git -C "$work/r" add -A
run
[ "$rc" = 1 ] && [ "$(grep -c 'docs/esc-title.md:1: no such tracked file' <<<"$out")" = 3 ] \
  || fail "a title holding its escaped delimiter must still make a link, in all three forms (exit $rc): $out"
ok "a title may hold its own delimiter escaped, in all three forms"
# The pattern spells the 2100 x's out: an interval such as x{2100} is past
# RE_DUP_MAX (255) on BSD regex, so macOS grep cannot match it.
long_stem="$(printf 'x%.0s' $(seq 1 2100))"; long_name="$long_stem.md"
expect_broken README.md "An <a href=\"docs/$long_name\">long</a>." \
  "no such tracked file or directory: docs/$long_stem\\.md\$" \
  "an HTML href over 2048 characters is still checked"
# No destination, title or anchor id has a length limit: a bound once
# skipped every link past it in silence.
expect_broken README.md "See [x](docs/$long_name)." \
  "^README\\.md:[0-9]+: no such tracked file or directory: docs/$long_stem\\.md\$" \
  "a broken destination over 2048 characters is reported"
expect_broken README.md "See [x](<docs/$long_name>)." \
  "^README\\.md:[0-9]+: no such tracked file or directory: docs/$long_stem\\.md\$" \
  "a broken <...> destination over 2048 characters is reported"
expect_broken README.md "See [x](docs/gone.md \"$long_stem\")." \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone\.md$' \
  "a broken destination with a title over 2048 characters is reported"
new_tree
printf '<a id="%s"></a>\n\n[x](#%s)\n' "$long_stem" "$long_stem" >"$work/r/docs/long-id.md"
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "an explicit <a id> over 2048 characters must be an anchor (exit $rc): $out"
ok "an explicit <a id> over 2048 characters is an anchor"
expect_broken README.md "$(printf 'See [z](docs/a\342\200\256b.md).')" \
  'docs/a\\u202eb\.md' \
  "a bidi override in a report prints as \\uHHHH"

# tty_safe escapes by Unicode category (ESCAPED_CATEGORIES in the gate), so the
# table below holds the boundaries of each range that matters: the last
# printable and first escaped character on each side. Every code point here
# keeps its category from Python 3.9 on (unicodedata follows the running
# Python's Unicode version, and only Cn moves, so the unassigned ones are
# noncharacters or blocks the standard reserves for good). The expectation is
# written out, never computed with the gate's own rule.
python3 -I -B - "$repo_root/tests" <<'PY' || fail "tty_safe: the escape table does not hold"
import sys
sys.path.insert(0, sys.argv[1])
import linkcheck

RAW = None
TABLE = [
    # C0 and C1: TAB stays, LF and DEL escape, the C1 block ends at U+009F.
    (0x08, "\\x08"), (0x09, RAW), (0x0A, "\\x0a"), (0x1F, "\\x1f"),
    (0x20, RAW), (0x7E, RAW), (0x7F, "\\x7f"), (0x80, "\\x80"),
    (0x9F, "\\x9f"), (0xA0, RAW), (0xA1, RAW),
    # Cf, with printable neighbours: the soft hyphen, the Arabic letter mark.
    (0xAC, RAW), (0xAD, "\\u00ad"), (0xAE, RAW), (0xE9, RAW), (0x4E2D, RAW),
    (0x0301, RAW),
    (0x061B, RAW), (0x061C, "\\u061c"), (0x0600, "\\u0600"),
    (0x180E, "\\u180e"),
    # General punctuation: spaces stay, zero-width and bidi controls escape.
    (0x200A, RAW), (0x200B, "\\u200b"), (0x200F, "\\u200f"), (0x2010, RAW),
    (0x2027, RAW), (0x2028, "\\u2028"), (0x2029, "\\u2029"),
    (0x202A, "\\u202a"), (0x202E, "\\u202e"), (0x202F, RAW), (0x205F, RAW),
    (0x2060, "\\u2060"), (0x2064, "\\u2064"), (0x2065, "\\u2065"),
    (0x2066, "\\u2066"), (0x2069, "\\u2069"), (0x206A, "\\u206a"),
    (0x206F, "\\u206f"), (0x2070, RAW),
    # Cn, Co and Cs on the BMP (U+FFFF is the last `\u` escape), and the BOM.
    # A combining mark (Mn, U+0301) is printable and stays raw.
    (0x0378, "\\u0378"), (0xDFFF, "\\udfff"), (0xE000, "\\ue000"),
    (0xF8FF, "\\uf8ff"), (0xFEFF, "\\ufeff"), (0xFFF9, "\\ufff9"),
    (0xFFFE, "\\ufffe"), (0xFFFF, "\\uffff"),
    # A lone surrogate is Cs, and DC80-DCFF is an undecodable byte, `\xHH`.
    (0xD800, "\\ud800"), (0xDC7F, "\\udc7f"), (0xDC80, "\\x80"),
    (0xDCFF, "\\xff"), (0xDD00, "\\udd00"),
    # Past U+FFFF the escape is `\U` plus eight digits, never `\u` plus five.
    (0x1D173, "\\U0001d173"), (0x1F600, RAW), (0xE0000, "\\U000e0000"),
    (0xE0001, "\\U000e0001"), (0xE0020, "\\U000e0020"),
    (0xE007F, "\\U000e007f"), (0xE0080, "\\U000e0080"),
    (0xF0000, "\\U000f0000"), (0x10FFFF, "\\U0010ffff"),
]
bad = []
for cp, want in TABLE:
    got = linkcheck.tty_safe(chr(cp))
    if got != (chr(cp) if want is RAW else want):
        bad.append("U+%04X: %r" % (cp, got))
if bad:
    sys.exit("; ".join(bad))
PY
ok "tty_safe escapes by Unicode category and leaves printable non-ASCII raw, at every range edge"

# A tag whose quote never closes is text, not a link: the same line's other
# links are still read, and the gate does not read to the end of the file for
# the quote. A newline right after the opening quote belongs to the value, so
# a broken target there is still reported.
new_tree
printf '%s\n' 'A <a href="docs/gone-unclosed.md and [x](docs/gone-after.md).' \
  >"$work/r/docs/unclosed.md"
printf '%s\n' 'A <a href="docs/gone-blank.md' '' 'closes later">x</a>' \
  >"$work/r/docs/quote-blank.md"
git -C "$work/r" add -A
run
[ "$rc" = 1 ] && grep -q 'docs/unclosed\.md:1: .*docs/gone-after\.md' <<<"$out" \
  && ! grep -q 'gone-unclosed' <<<"$out" && ! grep -q 'gone-blank' <<<"$out" \
  || fail "a tag with an unclosed quote, or a quote spanning a blank line, must be text and leave other links read (exit $rc): $out"
ok "a tag with an unclosed quote, or one crossing a blank line, is text, and the link after it is still checked"
new_tree
printf '%s\n' 'A <a href="docs/gone-lf.md' '">x</a>' >"$work/r/docs/quote-lf.md"
printf '%s\n' 'A <a href="' 'docs/gone-lf2.md">x</a>' >"$work/r/docs/quote-lf2.md"
printf "%s\n" "A <a href='" "docs/gone-lf3.md'>x</a>" >"$work/r/docs/quote-lf3.md"
git -C "$work/r" add -A
run
[ "$rc" = 1 ] && grep -q 'docs/quote-lf\.md:1: .*gone-lf\.md' <<<"$out" \
  && grep -q 'docs/quote-lf2\.md:1: .*gone-lf2\.md' <<<"$out" \
  && grep -q 'docs/quote-lf3\.md:1: .*gone-lf3\.md' <<<"$out" \
  || fail "a newline inside a quoted href must not hide its target (exit $rc): $out"
ok "a newline inside a quoted href, even right after the opening quote, still reports a broken target"

# A heading's code span is bounded at 2048 characters, for speed: one of
# exactly that length renders verbatim, one character longer is prose, so
# its emphasis underscores go (the bound is a deliberate cap, pinned here so
# a change to it is a decision). The span is `_x..._`: emphasis tells the
# two readings apart in the slug.
new_tree
python3 -I - "$work/r/docs" <<'PY'
import os, sys
d = sys.argv[1]
for name, n in (("span-in.md", 2048), ("span-out.md", 2049)):
    inner = "_" + "x" * (n - 2) + "_"
    slug = inner if n == 2048 else "x" * (n - 2)
    with open(os.path.join(d, name), "w") as f:
        f.write("# `%s`\n\n[self](#%s)\n" % (inner, slug))
PY
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "a heading code span of 2048 characters is verbatim, of 2049 prose (exit $rc): $out"
ok "a heading's code span is read verbatim up to 2048 characters and as prose past it"

# Hostile input stays near-linear: many unclosed comment openers, tag
# openers with no `>`, unclosed quotes, backtick runs of every length and
# unclosed brackets, 100 KB to just under the 1 MiB file cap each, in prose
# and in headings (a link with an #anchor into each file makes the heading
# pass read it too). The previous regexes were quadratic here (measured: one
# 200 KB line of `[a](b` alone, or of `<a `, outlived 20 s, and a single
# 200 KB heading of `[` or of `[a](x` did too), while every scan now takes
# well under a second, so the 30 s bound separates the two with room for a
# slow runner.
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
    "h4.md": "".join("`" * k + " x " for k in range(1, 1400)),
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
    "h16.md": "# " + "".join("`" * k + " x " for k in range(1, 1400)),
    "h17.md": "[a][" * (n // 4),
    # A heading link or image whose destination is unclosed after a run of
    # spaces and then a character (atx_text strips trailing spaces, so the
    # spaces must be followed by something): once quadratic, 200 KB outlived 60 s.
    "h18.md": "# [a](" + " " * n + "x",
    "h19.md": "# ![a](" + " " * n + "x",
    "h20.md": "# [a](x " + " " * n + '"',
    "h21.md": "# [a](" + "(x" * (n // 2),
    # Body destinations: balanced and unclosed parentheses, angle openers,
    # backslashes and every title form; `[a](<` once took 2 s at 200 KB.
    "h22.md": "[a](<" * (n // 4),
    "h23.md": "[a](x(y)" * (n // 8),
    "h24.md": "[a](x" + "(y)" * (n // 3),
    "h25.md": "[a](x(y(z(" * (n // 10),
    "h26.md": "[a](\\" * (n // 5),
    "h27.md": "[a](x 'y [a](x (y " * (n // 18),
    # Escaped brackets in link text, labels and definitions.
    "h28.md": "[\\" * (n // 2),
    "h29.md": "[a][b\\]" * (n // 7),
    "h30.md": "[b\\]]: x\n" * (n // 8),
    # Tags whose quoted values hold `>`, or never close, or never open.
    "h31.md": '<a t=">"' * (n // 8),
    "h32.md": "<a t='" * (n // 6),
    "h33.md": "<a t=\"x' " * (n // 9),
    "h34.md": "<a =" + " " * n + "x",
    # Unbounded titles and ids, escaped title delimiters, and open tags that
    # nest quote kinds, run a quoted value into a name, or never close.
    "h35.md": '[a](b "' + "x" * n,
    "h36.md": '[a](b "\\' * (n // 8),
    "h37.md": '<a id="x ' * (n // 9),
    "h38.md": "<a t=\"<a u='" * (n // 12),
    "h39.md": '<a t="' + "<a b " * (n // 5) + '" c="d"x',
    "h40.md": '<a t="x"y ' * (n // 10),
    "h41.md": "<a" + " a=b" * (n // 4),
    # Definitions with titles that never close, destinations on the next
    # line, backslash runs before `[`, attributes glued onto quoted values
    # or opening with a digit, and a destination of references.
    "h42.md": '[a]: b "x\n' * (n // 8),
    "h43.md": "[a]:\n" * (n // 5),
    "h44.md": "\\" * n + "[a](b",
    "h45.md": "\\\\[" * (n // 3),
    "h46.md": '<a x="y"' * (n // 8),
    "h47.md": "<a 1" * (n // 4),
    "h48.md": "[a](" + "&amp;" * (n // 5),
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
ok "hostile input (unclosed comments, tags, quotes, links, labels, backtick runs, brackets, escapes, nested destinations, long titles and ids, in prose and headings) finishes in bounded time"

# blank_spans must stay linear with no comment in the text. Two shapes, each
# a quadratic hazard of its own: many paired spans (scanning for the next
# `<!--` again at every span, when it answers -1 once, not once per run), and
# K runs of distinct lengths with no partner followed by M paired runs (a
# walk over the later runs to find a partner, instead of the one-pass lookup,
# costs K x M: 0.4 s against 16 s at K=600, M=120000). Compare growth, not
# wall time: each shape runs at 1x and 8x, a linear scan costs about 8x to 10x
# (up to 17x under load), a quadratic one 64x, so a ratio past 23 on the best
# of five runs, with the collector off, separates them on any runner. The
# 5 ms floor keeps a very fast 1x run from inflating the ratio.
python3 -I -B - "$repo_root/tests" <<'PY' || fail "blank_spans must scale linearly with no comment in the text"
import gc, sys, time
sys.path.insert(0, sys.argv[1])
import linkcheck

def best(text):
    lo = None
    gc.disable()
    try:
        for _ in range(5):
            t = time.perf_counter()
            linkcheck.blank_spans(text, True)
            dt = time.perf_counter() - t
            lo = dt if lo is None else min(lo, dt)
    finally:
        gc.enable()
    return lo

def pairs(n):
    return "`a` b " * n

def distinct_then_pairs(k, m):
    return "".join("`" * (j + 2) + " x " for j in range(k)) + pairs(m)

bad = []
for name, small, big in (
        ("paired spans", pairs(10000), pairs(80000)),
        ("distinct runs then pairs", distinct_then_pairs(100, 10000),
         distinct_then_pairs(800, 80000))):
    a, b = best(small), best(big)
    if b > 23 * max(a, 0.005):
        bad.append("%s: 8x cost %.1fx (%.3f s -> %.3f s)" % (name, b / a, a, b))
if bad:
    sys.exit("; ".join(bad))
PY
ok "blank_spans grows linearly with the number of code spans and unpartnered runs when no comment is open"

# A file over MAX_FILE_BYTES is refused, one at the cap is read: the cap is
# measured in bytes, before decoding, and read from the gate so the test
# follows it.
cap="$(python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import linkcheck; print(linkcheck.MAX_FILE_BYTES)' "$repo_root/tests")"
case "$cap" in ''|*[!0-9]*) fail "could not read MAX_FILE_BYTES from the gate: $cap" ;; esac
new_tree
python3 -I - "$work/r/docs/big.md" "$cap" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    f.write("x" * (int(sys.argv[2]) - 1) + "\n")
PY
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "a file of exactly MAX_FILE_BYTES must be read (exit $rc): $out"
printf 'y' >>"$work/r/docs/big.md"
run
[ "$rc" = 2 ] && grep -q 'docs/big\.md: over '"$cap"' bytes' <<<"$out" \
  || fail "a file one byte over MAX_FILE_BYTES must exit 2 (got $rc): $out"
ok "a file over the size cap exits 2 and one at the cap is read"

# The cap counts bytes, not characters: a file under it in characters and
# over it in bytes is refused. The name is hostile (ESC, U+202E): the error
# line must print it escaped.
new_tree
python3 -I - "$work/r/docs" "$cap" <<'PY'
import os, sys
d, cap = sys.argv[1], int(sys.argv[2])
with open(os.path.join(d, "wide\x1b\u202e.md"), "w", encoding="utf-8") as f:
    f.write("\u00e9" * (cap // 2 + 1))
PY
git -C "$work/r" add -A
run
[ "$rc" = 2 ] && grep -qF 'wide\x1b\u202e.md: over '"$cap"' bytes' <<<"$out" \
  && ! grep -q "$(printf '\033')" <<<"$out" \
  && ! grep -q "$(printf '\342\200\256')" <<<"$out" \
  || fail "a file over the cap in bytes, not in characters, must exit 2 with its name escaped (got $rc): $out"
ok "the cap counts bytes, and the over-cap error prints a hostile name escaped"

# A symlink swapped into the final component after realpath's check: the open
# itself refuses it (O_NOFOLLOW), with the same error as the check. realpath
# is stubbed to pass, which stands for losing that race.
new_tree
ln -s ../README.md "$work/r/docs/swapped.md"
python3 -I -B - "$repo_root/tests" "$work/r" <<'PY' || fail "O_NOFOLLOW: a final-component symlink must be refused"
import os, sys
sys.path.insert(0, sys.argv[1])
import linkcheck
linkcheck.os.path.realpath = lambda p: p
try:
    linkcheck.read_text(sys.argv[2], "docs/swapped.md")
except linkcheck.GateError as e:
    if "reached through a symlink" not in str(e):
        sys.exit("wrong message: %s" % e)
else:
    sys.exit("the symlink was read")
PY
ok "a symlink swapped into the final component after the check is refused at the open"

# A tracked file swapped for a FIFO must fail closed, not wait for a writer.
new_tree
rm "$work/r/docs/guide.md"; mkfifo "$work/r/docs/guide.md"
bounded_run 20 "$work/fifo.out" python3 -I -B "$gate" "$work/r" \
  || fail "FIFO: bounded_run could not turn job control on"
[ "$br_hung" = 0 ] && [ "$br_stuck" = 0 ] \
  || fail "FIFO: linkcheck blocked on a tracked file swapped for a FIFO"
[ "$br_rc" = 2 ] || fail "FIFO: expected exit 2, got $br_rc: $(cat "$work/fifo.out")"
ok "a tracked file swapped for a FIFO exits 2 without blocking"

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
