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
# An open tag is read as CommonMark reads raw HTML: a quoted value must be
# followed by whitespace, `/` or `>`, and no tag crosses a blank line. What
# fails that is text, so a tag inside it is still found.
expect_broken README.md "<a t='x <a href=\"docs/gone.md\">y</a>" \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone\.md$' \
  "a tag after an opener whose quote never closes is checked"
expect_broken README.md 'A stray <a title="oops in prose, then <a href="docs/gone.md">t</a> later.' \
  '^README\.md:[0-9]+: no such tracked file or directory: docs/gone\.md$' \
  "a tag inside the would-be quoted value of a stray opener is checked"
new_tree
printf '<a href="docs/gone.md"\n\n>x</a>\n\n<a title="x"y href="docs/gone-too.md">z</a>\n' \
  >"$work/r/docs/not-tags.md"
git -C "$work/r" add -A
run
[ "$rc" = 0 ] || fail "a tag across a blank line, or with a quoted value run into a name, is text (exit $rc): $out"
ok "a tag across a blank line, or with a quoted value run into a name, is text, not a tag"
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
