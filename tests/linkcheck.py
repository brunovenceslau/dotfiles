# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""linkcheck - the `make linkcheck` gate: every in-repo link in the docs resolves.

Usage: python3 -I tests/linkcheck.py [ROOT]    (ROOT default: the current directory)

ROOT must be the toplevel of a git checkout. The scanned set is what git
TRACKS there, never a directory walk: every `*.md` file that is a regular file
(a tracked symlink is skipped, since reading it would follow it wherever it
points), plus the issue-form YAML under .github/ISSUE_TEMPLATE/, which holds
absolute links back into this repository. Each link is checked against that
same tracked set:

  - the target of an inline link `[text](path#anchor)`, an image, a
    reference definition `[ref]: path` (its destination on the same line
    or the next, nothing but a title after it), and the `href` or `src` of
    an HTML `<a>` or `<img>` tag (quoted or bare) must name a tracked
    file, or a directory holding one, inside ROOT. A Markdown destination
    is read the CommonMark way: no ASCII whitespace, balanced parentheses
    (32 levels deep, GitHub's limit), backslash escapes of ASCII punctuation, or the `<...>`
    form, which may hold spaces; a title may follow, double- or
    single-quoted or in parentheses. Neither has a length limit. Escapes
    are undone and character references (`&amp;`) decoded before
    resolving, in an HTML value too. An untracked
    file on this machine does not count: GitHub
    renders the tracked tree, so a link to a gitignored `.local` file is broken
    there even though it resolves here. Case is compared exactly for the same
    reason (a case-insensitive APFS resolves `Docs/` where GitHub does not). A
    `?query` is dropped before resolving;
  - a full or collapsed reference link, `[text][ref]` or `[text][]`, must have
    a matching definition in the same file (labels compared case-folded, with
    whitespace collapsed). A backslash-escaped bracket does not end link
    text or a label, and an escaped quote or paren does not end a title;
    none of them crosses a blank line. A shortcut `[ref]` is not checked:
    it cannot be told apart from bracketed prose;
  - an `<a>` or `<img>` tag is read much the way GitHub's HTML5 parser
    reads an HTML block (the comment above HTML_OPENER names the known
    misses): a `>` inside a quoted value does not end it, and one that
    crosses a blank line is text, so a tag inside it is still found;
  - an `#anchor` into a Markdown file must match one of its headings under
    GitHub's slug rule (see slugify), repeats numbered -1, -2 the way
    github-slugger numbers them, or an explicit anchor, an `<a>` tag's
    `id` or `name`. An anchor into any other file (a `#L10` line anchor),
    or into a tracked symlink, is not checked;
  - an absolute `https://github.com/brunovenceslau/dotfiles/(blob|tree)/main/`
    link is resolved against the local tree the same way, in the YAML too.

Not links, so ignored: anything in YAML front matter, a fenced code block
(backticks or tildes, at any indent, running to the end of the file when never
closed, as GitHub renders it), an indented code block, an inline code span and
an HTML comment (also running to the end of the file when never closed).
Front matter that never closes is not front matter: GitHub renders its `---`
as a rule and the rest as prose, so its links are checked. Every CRLF is
read as a LF before anything else looks at the text, so a CRLF file behaves
exactly like its LF twin. A link whose text wraps across lines is still
found. External URLs (any other scheme, `mailto:` included) are out of
scope: this gate never touches the network, so its answer depends only on
the tree.

Hostile input stays near-linear. A pattern that could rescan the rest of a
line or file once per opener is bounded (a definition's label at
CommonMark's 999 characters, a heading's code span at 2048), stops at the
next opener of its kind (a title or an attribute value at its own quote,
never past a blank line), or crosses at most 32 later openers (a link
destination, since each opener brings an unclosed parenthesis and a 33rd
level ends it); everything else is a str.find loop or a lookup built in
one pass. No destination, title or attribute value has a length limit:
each of the others was bounded once, which silently skipped a long link,
and the test's hostile shapes, measured at 800 KB each, run in well under
a second without one. The comment above HTML_OPENER says why an open
tag's scan stays linear, and its memory bounded by one token.

Exit: 0 every link resolves; 1 a broken link (each printed as
FILE:LINE: reason: target, in sorted file order); 2 the gate itself could not
run (not a git toplevel, git failed or warned, an unreadable or non-UTF-8
file, one over MAX_FILE_BYTES, a file reached through a symlink swapped into
the working tree or no longer a regular file, any unexpected error). Exit 2
is never a pass. Every printed line goes through tty_safe, since it echoes
names and text from the scanned tree.

Python 3.9-safe: macOS's Command Line Tools python3 is 3.9.
"""

import bisect
import errno
import html
import html.entities
import os
import re
import stat
import subprocess
import sys
import unicodedata
from urllib.parse import unquote

# The repository's own identity. An absolute link to it is a relative link in
# disguise, and it breaks the same way when a file or heading is renamed.
SELF = re.compile(
    r"https://github\.com/brunovenceslau/dotfiles/(?:blob|tree)/main/([^\s)>\"'`]+)")

# A fence opens with 3+ backticks or tildes (any indent: a fence nested in a
# list item is indented past 3 columns) and closes with the same character,
# at least as long, alone on its line.
FENCE = re.compile(r"^[ \t]*(`{3,}|~{3,})")
LIST_ITEM = re.compile(r"^ {0,3}(?:[-*+]|[0-9]+[.)])(?:[ \t]|$)")
# An ATX heading opens with 1 to 6 `#` then a space, a tab or the end of the
# line. atx_text cuts its text out with str methods: a lazy `.*?` next to an
# optional closing sequence backtracked quadratically on a run of spaces.
ATX_OPEN = re.compile(r"^ {0,3}#{1,6}(?=[ \t]|$)")
# The same heading inside any depth of block quote or list item: the prefix is
# markers (`>`, a bullet, a number) with their padding, so `> ## H` and
# `- ## H` count, as the renderer reads them.
ATX_NESTED = re.compile(
    r"^(?:[ \t]*(?:>|[-*+]|[0-9]+[.)])(?=[ \t]|$))*[ \t]*#{1,6}(?=[ \t]|$)")
SETEXT = re.compile(r"^ {0,3}(=+|-+)[ \t]*$")
# A line break that is not a blank line: a paragraph, and an HTML block,
# ends at a blank line. The whitespace that may sit between the parts of a
# link or a tag (_skip_ws) is this, a space, a tab, CR, FF or VT: ASCII
# only. Python's `\s` also matches U+00A0, U+0085 and U+2028, which
# CommonMark reads as ordinary characters inside a destination.
_PARA = r"\n(?![ \t]*\n)"
# A link destination follows CommonMark, in the body and in a heading alike:
# no ASCII whitespace; a backslash escapes only ASCII punctuation (`\(` and
# `\)` included), else it is a literal; balanced parentheses nest; it never
# starts with `<`, since that opens the other form, `<...>`, which may hold
# spaces and an escaped `\>`. _dest_end reads both forms.
# Nesting stops at 32 levels, GitHub's own limit (cmark-gfm inlines.c,
# manual_scan_link_url_2: a 33rd open parenthesis ends the destination, and
# the link with it).
_PUNCT = r"[!-/:-@\[-`{-~]"
_PUNCT_SET = frozenset("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
_DEST_PLAIN_RUN = re.compile(r"[^()\\ \t\n\r\f\v]*")
_MAX_NEST = 32
# Either form is read the way the renderer reads it (md_dest), in one
# left-to-right pass as CommonMark does: a backslash escape is undone, and
# an entity or numeric character reference (CommonMark 2.5: always closed by
# `;`) is decoded, so `a\(b.md` names `a(b.md` and `a&amp;b.md` names
# `a&b.md`, while `\&amp;` stays the literal text `&amp;`. md_ref decodes
# the CommonMark way, not html.unescape's: a name must match an HTML5 entity
# exactly (`&ampx;` stays literal, where HTML's legacy rule reads `&amp`
# then `x;`), a reference with no `;` is never decoded in Markdown, and a
# number is its code point, U+FFFD only for 0, a surrogate or past
# U+10FFFF (HTML maps the C0 and C1 controls instead).
_ENTITY = r"&(?:#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z][A-Za-z0-9]{0,31});"
MD_DECODE = re.compile(r"\\(" + _PUNCT + ")|(" + _ENTITY + ")")
ENTITY = re.compile(_ENTITY)


def _span_char(c):
    """One character of a run that ends at c: never c unescaped (a
    backslash escapes it, `\\\\` being an escaped backslash) and never a
    blank line. The alternatives start on different characters (a lookahead
    splits the two backslash forms), so a run splits one way only."""
    return r"[^" + c + r"\\\n]|\\[^\n]|\\(?=\n)|" + _PARA


def _span_run(c, extra=""):
    """Any number of _span_char(c), unrolled: a plain run, then units that
    each open on a backslash or a line break (or extra, an alternative that
    opens on a character of c) followed by another plain run."""
    plain = r"[^" + c + r"\\\n]*"
    return (plain + r"(?:(?:\\[^\n]|\\(?=\n)|" + _PARA + extra + r")"
            + plain + r")*")


# Link text, a label and a title end at their own closer, never at an
# escaped one, and never cross a blank line.
_LABEL_CHAR = r"(?:" + _span_char(r"\[\]") + r")"
# An opening bracket counts only after an even run of backslashes (none
# included): the run is consumed whole from its start, which a lookbehind
# pins, so `\\[a](b)` is a link and `\[a](b)` is not. Linear: a run is
# entered only at its start.
_OPEN = r"(?<!\\)(?:\\\\)*\["
# [text](dest "title"): text may wrap across lines (never across a blank
# line) and may hold one level of nested brackets, which covers an image
# inside a link (a badge). The title is double-quoted, single-quoted or
# parenthesized. The destination is either form above, captured as group 2
# (`<...>`, without its brackets) or 3 (bare).
# A regex reads only the head, `[text](`; LinkPattern reads the rest with
# code (_link_tail), which takes the one parse the grammar allows: a bare
# destination is read whole (nothing it could give back would let the
# match succeed, since a destination never ends where a dest character
# follows), and a title, a destination and the blanks between them start on
# different characters. No regex holds that in bounded memory: re keeps
# about 290 bytes of stack for each repetition of a group, so one
# destination of 70000 `(y)` pairs took 42 MiB and a 200 KB unclosed one
# 48 MiB. The code reader keeps a depth count instead, and every run it
# reads is a single character class or a str.find. Linear: an opener's
# destination crosses at most 32 later openers, since each brings an
# unclosed parenthesis and a 33rd level ends it, and a title ends at the
# next quote of its kind (for a parenthesized one, the next unescaped `(` or
# `)`) or at a blank line.
TEXT = r"(" + _span_run(r"\[\]", r"|\[" + _span_run(r"\[\]") + r"\]") + r")"
_ANGLE_RUN = re.compile(r"[^<>\n\\]*")
_TITLE_RUN = {"\"": re.compile(r"[^\"\\\n]*"), "'": re.compile(r"[^'\\\n]*"),
              "(": re.compile(r"[^()\\\n]*")}


def _nest_end(text, i):
    """The end of the balanced parentheses opening at i, inside a bare
    destination, or None: a 33rd open level, ASCII whitespace (a line
    break included) or the end of the text first. A backslash escapes the punctuation after it, else is literal."""
    n, depth = len(text), 0
    while True:
        i = _DEST_PLAIN_RUN.match(text, i).end()
        if i >= n:
            return None
        c = text[i]
        if c == "\\":
            i += 2 if i + 1 < n and text[i + 1] in _PUNCT_SET else 1
        elif c == "(":
            depth += 1
            if depth > _MAX_NEST:
                return None
            i += 1
        elif c == ")":
            depth -= 1
            i += 1
            if depth == 0:
                return i
        else:
            return None   # whitespace


def _dest_end(text, i):
    """(end, angle) of the destination at i, angle True for the `<...>`
    form, or None when none is there."""
    n = len(text)
    if i < n and text[i] == "<":
        j = i + 1
        while True:
            j = _ANGLE_RUN.match(text, j).end()
            if j >= n or text[j] != "\\":
                return (j + 1, True) if j < n and text[j] == ">" else None
            if j + 1 >= n or text[j + 1] == "\n":
                return None
            j += 2
    j = i
    while True:
        j = _DEST_PLAIN_RUN.match(text, j).end()
        c = text[j] if j < n else ""
        if c == "\\":
            j += 2 if j + 1 < n and text[j + 1] in _PUNCT_SET else 1
        elif c == "(":
            e = _nest_end(text, j)
            if e is None:
                break   # unbalanced: the destination ends before it
            j = e
        else:
            break
    return (j, False) if j > i else None


def _title_end(text, i):
    """The end of the title opening at i (with `"`, `'` or `(`), or None:
    an unescaped opener of a parenthesized title, a blank line or the end
    of the text first."""
    n, close = len(text), ")" if text[i] == "(" else text[i]
    run = _TITLE_RUN[text[i]]
    j = i + 1
    while True:
        j = run.match(text, j).end()
        if j >= n:
            return None
        c = text[j]
        if c == close:
            return j + 1
        if c == "\\":
            if j + 1 >= n:
                return None
            j += 2 if text[j + 1] != "\n" else 1
        elif c == "\n" and not BLANK_LINE.match(text, j):
            j += 1
        else:
            return None


def _link_tail(text, i, optional):
    """(end, dest start, dest end, angle) of the tail after `(` at i: the
    destination (with optional, none at all), an optional title after
    whitespace, then `)`. None when the text there is no tail. dest start
    is -1 when there is no destination."""
    n = len(text)
    j = _skip_ws(text, i, False)
    d = _dest_end(text, j)
    if d is None:
        if optional and j < n and text[j] == ")":
            return j + 1, -1, -1, False
        return None
    e, angle = d
    k = _skip_ws(text, e, False)
    if k > e and k < n and text[k] in "\"'(":
        t = _title_end(text, k)
        if t is not None:
            # A title that reads leaves nothing else: without it, the text
            # at k is its opener, never the `)` that would end the tail.
            k = _skip_ws(text, t, False)
    if k < n and text[k] == ")":
        if angle:
            return k + 1, j + 1, e - 1, True
        return k + 1, j, e, False
    return None


class _LinkMatch(object):
    """The parts of an re match object the link passes read."""
    __slots__ = ("string", "_spans")

    def __init__(self, string, spans):
        self.string, self._spans = string, spans

    def span(self, g=0):
        return self._spans[g] or (-1, -1)

    def start(self, g=0):
        return self.span(g)[0]

    def end(self, g=0):
        return self.span(g)[1]

    def group(self, g=0):
        sp = self._spans[g]
        return None if sp is None else self.string[sp[0]:sp[1]]

    def groups(self):
        return tuple(self.group(g) for g in range(1, len(self._spans)))


_BLANKS = re.compile(r"[ \t]*")


def _def_tail(text, i):
    """_link_tail's form for a definition, whose destination starts at i:
    an optional title after blanks or one line break, then only blanks to
    the end of its line. A title that fails that leaves the definition
    ending at the destination."""
    n = len(text)
    d = _dest_end(text, i)
    if d is None:
        return None
    e, angle = d
    dest = (i + 1, e - 1) if angle else (i, e)
    s = _BLANKS.match(text, e).end()
    k = -1
    if s < n and text[s] == "\n":
        k = _BLANKS.match(text, s + 1).end()
    elif s > e:
        k = s
    if 0 <= k < n and text[k] in "\"'(":
        t = _title_end(text, k)
        if t is not None:
            r = _BLANKS.match(text, t).end()
            if r == n or text[r] == "\n":
                return (r,) + dest + (angle,)
    if s == n or text[s] == "\n":
        return (s,) + dest + (angle,)
    return None


class LinkPattern(object):
    """A link pattern with a regex head that ends where its tail starts,
    and tail(text, i) for the rest. Its matches are those of the single
    regex it replaced: group 1 the head's text or label, 2 an angle
    destination, and with bare, 3 a bare one."""

    def __init__(self, head, tail, bare):
        self.head, self.tail, self.bare = head, tail, bare

    def finditer(self, text):
        m = self.head.search(text)
        while m:
            t = self.tail(text, m.end())
            if t is None:
                m = self.head.search(text, m.start() + 1)
                continue
            end, ds, de, angle = t
            dest = (ds, de) if ds >= 0 else None
            spans = [(m.start(), end), m.span(1), dest if angle else None]
            if self.bare:
                spans.append(None if angle else dest)
            yield _LinkMatch(text, spans)
            m = self.head.search(text, end)


LINK = LinkPattern(re.compile(_OPEN + TEXT + r"\]\("),
                   lambda text, i: _link_tail(text, i, False), True)
REFLINK = re.compile(r"(?<!\])" + _OPEN + TEXT + r"\]\[(" + _span_run(r"\[\]") + r")\]")
# A definition (CommonMark 4.7): a label of at most 999 characters (an
# escape pair counts as one here, so the bound is loose by at most half;
# unbounded, each line opening with `[` scanned the rest of the file for a
# `]`), a colon, the destination on the same line or the next (group 2 a
# `<...>` one, group 3 a bare one), and an optional title after whitespace,
# itself on the same line or the next. Only spaces may follow on its last
# line; a title that fails that leaves the definition ending at the
# destination, and anything else after the destination is no definition.
REFDEF = LinkPattern(re.compile(r"^ {0,3}\[(" + _LABEL_CHAR + r"{1,999})\]:[ \t]*(?:\n[ \t]*)?",
                                re.M), _def_tail, True)
# An `<a>` or `<img>` open tag. In a paragraph CommonMark (6.6) reads raw
# HTML strictly, but in an HTML block (4.6, under a `<div>`) GitHub's HTML5
# parser takes what 6.6 refuses, such as an attribute run straight onto a
# quoted value (`title="x"y`) or a name opening with a digit (`1x`), and
# renders a live link. The gate takes the lenient reading, since missing a
# live link is the costly mistake. It keeps two rules both readings share:
# a `>` inside a quoted value does not end the tag, and no tag crosses a
# blank line. Anything else is text, so a tag inside it is still found.
# It follows the HTML5 tokenizer where that is cheap: a `/` between
# attributes is a separator (`<a/href="t.md">`), a name may open with `=`
# (`<a =x href="t.md">`) and hold a `<` (`<a x<y href="t.md">`), and a
# name followed by `=` always takes a value, so a name has one parse only.
# One divergence is kept: a `<` that opens another `<a` or `<img` inside a
# name ends the scan (`<a x<a href="t.md">`). The outer tag is then no tag
# and the inner one is read on its own, so its href is still checked, but an
# id or name after the inner opener is credited to the inner tag, where
# HTML5 gives it to the outer one. That keeps the scans of openers from
# overlapping, so unclosed tags stay linear.
# _tag_walk reads a tag left to right, one token at a time, and takes the
# one parse there is: a name, a bare value and a quoted value start on
# different characters, a name follows whitespace and `/` or a closing quote
# only, a name followed by `=` always takes a value, and the end of the tag
# and the next attribute never both fit. Linear: a `<` outside a quoted value
# or a name ends an opener's scan, and an opener inside another's quoted
# value runs on only through a value of the other quote kind, so scans
# overlap at most two deep; a quoted value is found by str.find, which ends
# at the next quote of its kind, so the values of one kind never overlap.
# Memory stays bounded by one token: every run is one character class, which
# re repeats with no backtracking stack, or a str.find, never a repeated
# group. The single regex this replaced held about 300 bytes of stack per
# character of one tag (an unclosed tag of 130000 attributes took 200 MiB).
HTML_OPENER = re.compile(r"<(a|img)", re.I)
_SPACE_RUN = re.compile(r"[ \t\r\f\v]*")
_SEP_RUN = re.compile(r"[ \t\r\f\v/]*")
_NAME_RUN = re.compile(r"[^ \t\n\r\f\v\"'=<>/]*")
_BARE_VALUE = re.compile(r"[^ \t\n\r\f\v\"'<>]+")
_INNER_OPENER = re.compile(r"(?i:a|img)[ \t\n\r\f\v/>]")
_NOT_NAME_START = " \t\n\r\f\v\"'<>/"


def _skip_ws(text, i, slash):
    """The end of the run of whitespace (with slash, of whitespace and `/`)
    at i. A newline that opens a blank line ends the run: no tag crosses
    one."""
    run = _SEP_RUN if slash else _SPACE_RUN
    while True:
        i = run.match(text, i).end()
        if i < len(text) and text[i] == "\n" and not BLANK_LINE.match(text, i):
            i += 1
        else:
            return i


def _tag_walk(text, m):
    """Walk the `<a` or `<img` open tag that HTML_OPENER matched as m: yield
    (name, offset, value) for each attribute given a value, name lowercased
    and offset where the value starts in text, then, last, the tag's end, or
    -1 when the text there is no tag. A generator, so no list of a long
    tag's attributes is ever held: html_tags walks a tag once to find its
    end, and html_attrs walks a tag again only once it is known to be one."""
    n = len(text)
    i = m.end()
    while True:
        # The tag's end: whitespace, an optional `/`, then `>`.
        j = _skip_ws(text, i, False)
        if j < n and text[j] == "/":
            j += 1
        if j < n and text[j] == ">":
            yield j + 1
            return
        # Else one more attribute, after a separator, or right after a
        # closing quote with none.
        j = _skip_ws(text, i, True)
        if j == i and text[i - 1] not in "\"'":
            break
        # Its name: one character other than whitespace, a quote, `<`, `>`
        # or `/` (so it may open with `=`), then a run that may also hold a
        # `<` that does not open another `<a` or `<img`.
        if j >= n or text[j] in _NOT_NAME_START:
            break
        k = j + 1
        while True:
            k = _NAME_RUN.match(text, k).end()
            if k < n and text[k] == "<" and not _INNER_OPENER.match(text, k + 1):
                k += 1
            else:
                break
        e = _skip_ws(text, k, False)
        if e >= n or text[e] != "=":
            i = k   # no value
            continue
        v = _skip_ws(text, e + 1, False)
        if v < n and text[v] in "\"'":
            close = text.find(text[v], v + 1)
            if close < 0 or BLANK_LINE.search(text, v + 1, close):
                break
            yield text[j:k].lower(), v + 1, text[v + 1:close]
            i = close + 1
            continue
        # A bare value is read whole, `/` included, as HTML5 reads one. The
        # regex this replaced could also end it before a `/` when the whole
        # reading failed, a second parse its attribute walk did not follow.
        b = _BARE_VALUE.match(text, v)
        if b is None:
            break
        yield text[j:k].lower(), v, b.group()
        i = b.end()
    yield -1


def html_tags(text, i=0):
    """(start, end, tag) of every `<a` or `<img` open tag from i on, left to
    right, none inside another, tag lowercased."""
    m = HTML_OPENER.search(text, i)
    while m:
        for end in _tag_walk(text, m):
            pass
        if end < 0:
            m = HTML_OPENER.search(text, m.start() + 1)
        else:
            yield m.start(), end, m.group(1).lower()
            m = HTML_OPENER.search(text, end)


SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
BLANK_LINE = re.compile(r"\n[ \t]*\n")
MODE_SYMLINK, MODE_GITLINK = "120000", "160000"
# Escaped by Unicode general category, not by range: Cc (controls), Cf
# (format: soft hyphen, zero-width space and joiners, bidi marks, embeddings,
# overrides and isolates, word joiner, BOM, tag characters), Zl and Zp (the
# line and paragraph separators), Co (private use), Cs (a lone surrogate) and
# Cn (unassigned). Each reorders, hides or has no fixed shape on a terminal.
# unicodedata follows the running Python's Unicode version, so Cn is the one
# category that moves: a code point assigned after this Python's tables
# prints escaped here and raw on a newer Python. That errs on the safe side,
# and no category here ever turns printable.
ESCAPED_CATEGORIES = frozenset(["Cc", "Cf", "Zl", "Zp", "Co", "Cs", "Cn"])


# A tracked Markdown file over this is refused (exit 2), never read: the
# worst-case scan costs about 4 to 5 s per MB (measured on #36), so an
# unbounded file would stall the gate. 1 MiB is 16 times the largest tracked
# page (63 KB at the time of writing).
MAX_FILE_BYTES = 1 << 20


class GateError(Exception):
    """The gate could not do its job: exit 2, never a pass."""


def tty_safe(s):
    """Escape what a terminal would act on, the rule bin/check-patterns'
    sanitizer applies: C0 controls but TAB, DEL, and C1 (U+0080 to U+009F),
    printed as `\\xHH`. LF is escaped too, since each report is one line and
    a name holding one would forge a second. A byte that was not UTF-8
    (decoded with surrogateescape) prints as its `\\xHH` as well. Beyond
    that rule, a character of ESCAPED_CATEGORIES prints as `\\uHHHH`
    (`\\UHHHHHHHH` past U+FFFF, so the digits never run together): those
    reorder or hide text, or have no fixed shape. Characters outside those
    categories print raw even when they look blank or alike (a space
    separator such as U+00A0, a variation selector, a Hangul filler), so a
    report is not proof against look-alike names.
    Printable non-ASCII (U+00E9) stays raw."""
    out = []
    for ch in s:
        o = ord(ch)
        if 0xDC80 <= o <= 0xDCFF:
            out.append("\\x%02x" % (o - 0xDC00))
        elif (o < 0x20 and ch != "\t") or 0x7F <= o <= 0x9F:
            out.append("\\x%02x" % o)
        elif o > 0x7F and unicodedata.category(ch) in ESCAPED_CATEGORIES:
            out.append("\\u%04x" % o if o <= 0xFFFF else "\\U%08x" % o)
        else:
            out.append(ch)
    return "".join(out)


def git(root, *args):
    # stderr is part of the answer: git exits 0 and only WARNS when it drops
    # entries it cannot read, so a warning fails closed like an error.
    p = subprocess.run(["git", "-C", root] + list(args),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0 or p.stderr:
        raise GateError("git %s failed (exit %d): %s" % (
            " ".join(args), p.returncode,
            p.stderr.decode("utf-8", "surrogateescape").strip()))
    return p.stdout


def read_text(root, rel):
    """A tracked file's text, read only where git says it is: a working-tree
    symlink swapped in for the file or any directory above it (which git
    cannot see in the index) would read a file outside ROOT."""
    path = os.path.join(root, rel)
    if os.path.realpath(path) != os.path.join(root, os.path.normpath(rel)):
        raise GateError("%s: reached through a symlink in the working tree" % rel)
    try:
        # O_NONBLOCK: opening a FIFO swapped in after main's isfile check
        # would otherwise wait for a writer forever. O_NOFOLLOW: realpath
        # above refuses a symlink anywhere in the path at check time, and
        # this refuses one swapped into the FINAL component between that
        # check and the open (it covers the final component only); the
        # kernel answers ELOOP, reported as the same symlink error.
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0)
                     | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                raise GateError("%s: tracked as a regular file but not one "
                                "in the working tree" % rel)
            # One byte past the cap, so a file that grew after git listed it
            # is refused too, and an oversized one is never read whole.
            data = f.read(MAX_FILE_BYTES + 1)
    except OSError as e:
        if e.errno == errno.ELOOP:
            raise GateError("%s: reached through a symlink in the working tree" % rel)
        raise GateError("%s: %s" % (rel, e.strerror))
    if len(data) > MAX_FILE_BYTES:
        raise GateError("%s: over %d bytes, too large to check in bounded time"
                        % (rel, MAX_FILE_BYTES))
    try:
        # One normalization here, so no later reader has to strip a CR.
        return data.decode("utf-8").replace("\r\n", "\n")
    except UnicodeDecodeError as e:
        raise GateError("%s: not UTF-8 (%s)" % (rel, e.reason))


def blank(s):
    """Same length and line breaks, no content, so offsets and line numbers hold."""
    return re.sub(r"[^\n]", " ", s)


def indent_of(ln):
    return len(ln.expandtabs(4)) - len(ln.expandtabs(4).lstrip(" "))


def strip_blocks(text):
    """Blank what is not prose at block level: front matter, fenced and
    indented code blocks. Every blanked character becomes a space, so offsets
    and line numbers still point into the file; blank_spans does the inline
    half (comments and code spans)."""
    lines = text.split("\n")
    out = []
    i = 0
    if lines and lines[0] == "---":
        # YAML front matter (the .claude/rules pages): not rendered as prose.
        for j in range(1, len(lines)):
            if lines[j] == "---":
                out = [blank(x) for x in lines[:j + 1]]
                i = j + 1
                break
    fence = None
    prev_blank, in_list, in_icode = True, False, False
    for ln in lines[i:]:
        m = FENCE.match(ln)
        if fence is not None:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) \
                    and ln.strip() == m.group(1):
                fence = None
            out.append(blank(ln))
            continue
        if m:
            fence = m.group(1)
            out.append(blank(ln))
            prev_blank, in_icode = False, False
            continue
        if not ln.strip():
            out.append(ln)
            prev_blank = True
            continue
        ind = indent_of(ln)
        # An indented code block: 4+ columns, opened only after a blank line
        # (it cannot interrupt a paragraph) and never inside a list, where the
        # same indent is the item's own content.
        if ind >= 4 and not in_list and (prev_blank or in_icode):
            out.append(blank(ln))
            in_icode, prev_blank = True, False
            continue
        if LIST_ITEM.match(ln):
            in_list = True
        elif ind == 0 and prev_blank:
            in_list = False
        out.append(ln)
        prev_blank, in_icode = False, False
    return "\n".join(out)


def blank_spans(text, spans):
    """Blank HTML comments, and with spans code spans, in one left-to-right
    pass: whichever opens first wins, so a `<!--` inside a code span is text
    and a backtick inside a comment opens nothing. A code span is a run of N
    backticks up to the next run of exactly N in the same paragraph; a run
    with no partner is literal text. A comment never closed runs to the end
    of the file, as an HTML block does.
    Hostile input (many openers, none closed) stays linear: every backtick
    run is listed once with the next run of its own length (nxt), so finding
    a partner is a lookup, not a scan per opener (a line of runs of every
    length 1..k cost one scan per length); a paragraph's end is found once
    per paragraph; and the next `<!--` (and, with spans, the next `<a` or
    `<img` tag) is searched again only once the scan has passed it (a file
    with none answers -1 once, not once per run).
    Two things bind as tightly as a span and win when they come first: a
    backslash (an odd run of them) before a backtick, which then opens
    nothing (it can still close a span, since backslashes are literal in
    code), and an `<a>` or `<img>` open tag, whose quoted values may hold
    backticks. Other tags are not tracked (a known miss: a backtick in
    another tag's attribute can pair with a later one)."""
    n = len(text)
    ends = [m.start() for m in BLANK_LINE.finditer(text)] + [n]
    runs = [(m.start(), m.end() - m.start()) for m in re.finditer("`+", text)]
    run_at = {start: k for k, (start, _) in enumerate(runs)}
    nxt, last = [None] * len(runs), {}
    for k in range(len(runs) - 1, -1, -1):
        nxt[k] = last.get(runs[k][1])
        last[runs[k][1]] = k
    pieces, i, e, r = [], 0, 0, 0
    c = text.find("<!--")
    tag = next(html_tags(text), None) if spans else None
    t = tag[0] if tag else -1
    while i < n:
        if 0 <= c < i:
            c = text.find("<!--", i)
        if 0 <= t < i:
            tag = next(html_tags(text, i), None)
            t = tag[0] if tag else -1
        while r < len(runs) and runs[r][0] < i:
            r += 1
        a = runs[r][0] if r < len(runs) else -1
        if a < 0 and c < 0 and t < 0:
            break
        if t >= 0 and (a < 0 or t < a) and (c < 0 or t < c):
            pieces.append(text[i:tag[1]])
            i = tag[1]
            continue
        if c >= 0 and (a < 0 or c < a):
            close = text.find("-->", c + 4)
            end = n if close < 0 else close + 3
            pieces.append(text[i:c])
            pieces.append(blank(text[c:end]))
            i = end
            continue
        # Every opener is a whole run: i only ever lands after a run, after
        # a comment's `>`, or at 0, never inside a run.
        k = run_at[a]
        run = runs[k][1]
        b = a
        while b > 0 and text[b - 1] == "\\":
            b -= 1
        if (a - b) % 2:
            pieces.append(text[i:a + run])   # escaped: literal backticks
            i = a + run
            continue
        while ends[e] < a:
            e += 1
        partner = nxt[k]
        if partner is None or runs[partner][0] >= ends[e]:
            pieces.append(text[i:a + run])   # an unmatched run is literal backticks
            i = a + run
            continue
        close = runs[partner][0]
        pieces.append(text[i:a])
        span = text[a:close + run]
        pieces.append(blank(span) if spans else span)
        i = close + run
    pieces.append(text[i:])
    return "".join(pieces)


# What _render_inline reads token by token, left to right, so each wins
# where it comes first: a backslash escape (an escaped `<` opens nothing), and
# an autolink, `<` then a URI (a scheme of 2 to 32 characters, a colon, no
# control character, space, `<` or `>`) or an email address, then `>` (the
# patterns of cmark-gfm's scanners.re, _scan_autolink_uri and
# _scan_autolink_email). An autolink renders as its text, the address as
# written, where any other `<...>` is a tag and renders as nothing.
_AUTOLINK_EMAIL = (r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}"
                   r"[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*")
INLINE_TOKEN = re.compile(r"\\(" + _PUNCT + r")|<([A-Za-z][A-Za-z0-9.+-]{1,31}:[^\x00-\x20<>]*|"
                          + _AUTOLINK_EMAIL + ")>")


def _render_inline(s):
    """Rendered text of a heading fragment that holds no code span."""
    out, pos = [], 0
    for m in INLINE_TOKEN.finditer(s):
        out.append(_render_plain(s[pos:m.start()]))
        out.append(m.group(1) or m.group(2))   # an escaped char, or an autolink's text
        pos = m.end()
    out.append(_render_plain(s[pos:]))
    return "".join(out)


def _render_plain(p):
    """The text between tokens: HTML tags render as nothing, emphasis markers
    are dropped. An escaped `_` or `*` never gets here, so it stays literal."""
    p = re.sub(r"<[^<>]+>", "", p)                        # HTML tags render as nothing
    return re.sub(r"(?<![\w])[*_]+|[*_]+(?![\w])", "", p)   # emphasis, not intra-word _


def atx_text(rest):
    """An ATX heading's text: `rest` (what follows the `#`s) without its
    padding and its optional closing `#`s, which close only after a space or
    a tab, or when they are all there is (`## ##` is an empty heading)."""
    rest = rest.strip(" \t")
    bare = rest.rstrip("#")
    if not bare:
        return ""
    if bare != rest and bare[-1] in " \t":
        return bare.rstrip(" \t")
    return rest


# A link inside a heading, for slugify: it renders as its text, whatever its
# destination and title (the rules above LINK). Unlike a body link, its
# destination may be absent (`[a]()`), so its tail is read with optional set.
# An image shares the link's tail, else the `[alt](...)` part of an image with
# a title would match as a link and leak its alt text; an escaped `!` makes it
# a plain link.
HEADING_IMAGE = LinkPattern(re.compile(r"(?<!\\)!\[([^\[\]]*)\]\("),
                            lambda text, i: _link_tail(text, i, True), False)
# An opening bracket counts after an even run of backslashes only (_OPEN), so
# the match may start with that run: heading_link_text puts it back.
HEADING_LINK = LinkPattern(re.compile(_OPEN + r"([^\[\]]*)\]\("),
                           lambda text, i: _link_tail(text, i, True), False)


def heading_link_text(m, text):
    """A heading link's replacement: its text, after the backslash run (an
    even one, so a literal pair) that opened the match."""
    return text[m.start():m.start(1) - 1] + text[m.start(1):m.end(1)]


# A code span in one line: N backticks up to the next run of exactly N. A
# backslash escape is consumed first (alternative 1), so an escaped backtick
# opens nothing; inside a span backslashes are literal, and the span's
# content is consumed whole, so they are never seen as escapes.
_SPAN = re.compile(r"\\[!-/:-@\[-`{-~]|(?<!`)(`+)(?!`)(.{1,2048}?)(?<!`)\1(?!`)")


def _code_spans(text):
    """[(start, end, content)] of the code spans of one line. A span binds
    tighter than link syntax (CommonMark 6.1) except where a link's
    destination or title holds the backtick: `[a](u`) `b`` is a link and a
    span, not a span over `) `. So the spans are found once. A link or
    image that opens outside them marks its destination and title as a zone
    where no backtick opens or closes anything, unless a span opens in its
    text and runs past it (that span takes the `](`: `[`a](u`)` is `a](u`
    in code). The spans are then found again with the zones hidden."""
    spans = [m for m in _SPAN.finditer(text) if m.group(1)]
    if not spans:
        return []
    # Linear: the spans are sorted and disjoint, so one bisect places a
    # match, and the text is cut once, not once per link.
    starts = [m.start() for m in spans]
    zones = []
    for rx in (HEADING_IMAGE, HEADING_LINK):
        for m in rx.finditer(text):
            k = bisect.bisect_right(starts, m.start()) - 1
            if k >= 0 and m.start() < spans[k].end():
                continue   # the link opens inside a span: code
            j = bisect.bisect_left(starts, m.end(1)) - 1
            if j > k and spans[j].end() > m.end(1):
                continue   # a span opens in its text and runs past it
            zones.append((m.end(1) + 1, m.end()))
    pieces, pos = [], 0
    for a, b in sorted(zones):
        if a >= pos:
            pieces.append(text[pos:a])
            pieces.append(text[a:b].replace("`", "\x01"))
            pos = b
    hidden = "".join(pieces) + text[pos:]
    return [(m.start(), m.end(), m.group(2))
            for m in _SPAN.finditer(hidden) if m.group(1)]


def _sub_outside_spans(rx, repl, text):
    """rx.sub over text, never matching into a code span (see _code_spans).
    Each span is masked with a same-length filler for the search;
    repl(m, text) builds the replacement from the original text."""
    masked, pos = [], 0
    for a, b, _ in _code_spans(text):
        masked.append(text[pos:a] + "x" * (b - a))
        pos = b
    masked.append(text[pos:])
    out, pos = [], 0
    for m in rx.finditer("".join(masked)):
        out.append(text[pos:m.start()])
        out.append(repl(m, text))
        pos = m.end()
    out.append(text[pos:])
    return "".join(out)


def slugify(text):
    """GitHub's heading id: the rendered text, lowercased, with every character
    that is not a letter, mark, number, connector (`_`), hyphen or space
    dropped, and each space turned into `-`. No collapsing, no trimming of
    inner hyphens: `a - b` is `a---b`, as github-slugger makes it. A code
    span renders verbatim, so emphasis and escape rules stop at its edges:
    `_link_bin_tree` keeps both underscores."""
    # Every class below stops at its own opener or is bounded, so a heading
    # line of unclosed `[`, `(`, `<` or backticks costs near-linear time.
    # html-pipeline builds the id from the rendered text, and an image adds
    # none, so `![i](u) Foo` keeps its leading space and gets a leading hyphen.
    # A NUL stands in for the image: it is not whitespace, so the strip below
    # leaves the space beside it, and the character loop drops it.
    text = _sub_outside_spans(HEADING_IMAGE, lambda m, t: "\0", text.strip())
    # a link renders as its text
    text = _sub_outside_spans(HEADING_LINK, heading_link_text, text)
    rendered, pos = [], 0
    # The code span's 2048 bound is the one kept for speed, by measurement:
    # unbounded, a heading of backtick runs of every length 1..2000 (2 MB)
    # took 26 s, against 0.3 s bounded, since each unpartnered run scans
    # the rest of the line. A heading's code span never comes near 2048.
    for a, b, content in _code_spans(text):
        rendered.append(_render_inline(text[pos:a]))
        # One space of padding on both sides is not part of the code, unless
        # the span is all spaces (CommonMark 6.1).
        if len(content) > 2 and content[0] == content[-1] == " " and content.strip(" "):
            content = content[1:-1]
        rendered.append(content)
        pos = b
    rendered.append(_render_inline(text[pos:]))
    # No strip here: html-pipeline's TocFilter takes the heading's text
    # content as it is, so the padding a code span keeps (` `  a`` is two
    # spaces) is part of the id, like the space beside an image above. The
    # heading's own padding is gone already (atx_text, text.strip() above).
    text = "".join(rendered).lower()
    out = []
    for ch in text:
        cat = unicodedata.category(ch)
        if ch == " ":
            out.append("-")
        elif ch == "-" or cat[0] in "LMN" or cat == "Pc":
            out.append(ch)
    return "".join(out)


class Slugger:
    """github-slugger's numbering: a slug already taken gets -1, -2, ... after
    its BASE, and every slug handed out is taken too, so a heading that
    literally reads `foo-1` is not handed the same id as the second `foo`."""

    def __init__(self):
        self.taken = {}

    def slug(self, heading):
        base = result = slugify(heading)
        while result in self.taken:
            self.taken[base] += 1
            result = "%s-%d" % (base, self.taken[base])
        self.taken[result] = 0
        return result


def md_ref(ref):
    """The text a CommonMark entity or numeric reference (`&...;`) stands for."""
    if ref[1] == "#":
        n = int(ref[3:-1], 16) if ref[2] in "xX" else int(ref[2:-1])
        return chr(0xFFFD) if n == 0 or 0xD800 <= n < 0xE000 or n > 0x10FFFF else chr(n)
    return html.entities.html5.get(ref[1:], ref)


def md_dest(s):
    return MD_DECODE.sub(lambda m: m.group(1) or md_ref(m.group(2)), s)


def html_value(s):
    """An HTML attribute value as the browser reads it: references decoded
    by HTML's own rules (html.unescape), not CommonMark's."""
    return ENTITY.sub(lambda m: html.unescape(m.group()), s)


URL_CTL = re.compile("[\t\n\r]")


def html_url(s):
    """An href or src as a URL parser takes it: the URL standard strips the
    leading and trailing C0 controls and spaces (U+0000 to U+0020) first,
    then deletes every tab and newline inside, so `href="` + LF + `docs/x.md"`
    names docs/x.md and so does `docs/x.` + LF + `md`."""
    return URL_CTL.sub("", html_value(s).strip("".join(map(chr, range(0x21)))))


def html_attrs(text):
    """(tag, name, offset, value) of every attribute given a value in an
    `<a>` or `<img>` open tag, tag and name lowercased."""
    for start, _, tag in html_tags(text):
        for a in _tag_walk(text, HTML_OPENER.match(text, start)):
            if isinstance(a, tuple):
                yield (tag,) + a


def ref_label(s):
    return " ".join(s.split()).casefold()


class Tree:
    def __init__(self, root):
        self.root = root
        self.modes = {}
        self.dirs = {""}
        raw = git(root, "ls-files", "-s", "-z", "--cached")
        for rec in raw.decode("utf-8", "surrogateescape").split("\0"):
            if not rec:
                continue
            meta, sep, f = rec.partition("\t")
            if not sep or len(meta.split(" ")) != 3:
                raise GateError("git ls-files -s: malformed record %r" % rec)
            self.modes[f] = meta.split(" ")[0]
            d = os.path.dirname(f)
            while d not in self.dirs:
                self.dirs.add(d)
                d = os.path.dirname(d)
        self._anchors = {}

    def is_regular(self, rel):
        return self.modes.get(rel) not in (None, MODE_SYMLINK, MODE_GITLINK)

    def anchors(self, rel):
        if rel not in self._anchors:
            blocks = strip_blocks(read_text(self.root, rel))
            text = blank_spans(blocks, False)
            lines = text.split("\n")
            slugger, res = Slugger(), set()
            # An explicit anchor: an `<a>`'s id or name, the set the gate
            # has always read. Whether GitHub keeps an id on other tags is
            # unverified, and counting one it drops would hide a broken link.
            # Read with spans blanked: inside a code span a tag is text, so
            # only a heading keeps a span (its text is part of the id).
            for tag, name, _, value in html_attrs(blank_spans(blocks, True)):
                if tag == "a" and name in ("id", "name"):
                    res.add(html_value(value))
            for i, ln in enumerate(lines):
                heading = None
                m = ATX_OPEN.match(ln)
                if m:
                    heading = atx_text(ln[m.end():])
                elif i + 1 < len(lines) and ln.strip() and SETEXT.match(lines[i + 1]) \
                        and not FENCE.match(ln) and not LIST_ITEM.match(ln):
                    # A setext heading: text underlined by === or ---. A `---`
                    # under a blank line is a thematic break, excluded by the
                    # ln.strip() test.
                    heading = ln.strip()
                if heading is not None:
                    res.add(slugger.slug(heading))
            self._anchors[rel] = res
        return self._anchors[rel]


def resolve(tree, src_rel, target):
    """Return an error string for a broken target, or None."""
    path, _, frag = target.partition("#")
    path = path.partition("?")[0]   # `?plain=1` and the like select a view, not a file
    path, frag = unquote(path), unquote(frag)
    if path.startswith("/"):
        return "absolute path (GitHub resolves it against the host, not the repository)"
    if path:
        dest = os.path.normpath(os.path.join(os.path.dirname(src_rel), path))
        if dest == ".":
            dest = ""
        if dest == ".." or dest.startswith("../"):
            return "leaves the repository"
    else:
        dest = src_rel
    if dest not in tree.modes and dest not in tree.dirs:
        return "no such tracked file or directory"
    if frag and dest.endswith(".md") and tree.is_regular(dest) \
            and frag not in tree.anchors(dest):
        return "no such anchor in %s" % dest
    return None


class Lines:
    """Offset to line number by bisecting the newline offsets, found once
    per file: counting newlines per link was O(file) for each one."""

    def __init__(self, text):
        self.nl = [m.start() for m in re.finditer("\n", text)]

    def of(self, offset):
        return bisect.bisect_left(self.nl, offset) + 1

    def start(self, offset):
        """The offset where the line holding `offset` begins."""
        k = bisect.bisect_left(self.nl, offset)
        return self.nl[k - 1] + 1 if k else 0


def backtick_links(prose, code_free, lines):
    """(offset, tail) of each body link whose destination or title holds a
    backtick. `prose` is the text with comments blanked and code spans left
    in; `code_free` is the same with the spans blanked too, which is what the
    link pass reads. A backtick there can open a code span that pairs with a
    later one and hides the link from that pass, so the gate cannot tell
    whether the link is live: it reports the link instead of guessing. A `[`
    that sits in a code span is code, not a link. A heading (ATX, at any
    block quote or list depth) is read with the link-aware _code_spans, the
    way slugify reads it: the link is code, and not reported, when a span
    covers its `[` or its `]`, as in `[`a](u`) here`, where the span opens in
    the link text and takes the `](`. Any other heading link is reported like
    a body one, because the link pass cannot see it when a later backtick
    pairs with the one in its destination. A body line is not read this way:
    there `[`a](gone.md`) here.` is still reported (fail closed), while the
    heading form of it is skipped because a span covers its brackets. A
    definition is read the same way as a link, by REFDEF."""
    for m in REFDEF.finditer(prose):
        g = 2 if m.group(2) is not None else 3
        tail = prose[m.start(g):m.end()]
        if "`" in tail and code_free[m.start(1) - 1] == "[":
            yield m.start(g), tail
    heads = {}   # line start -> (span starts, spans) of a heading, else None
    pending = [(0, prose)]
    while pending:
        base, text = pending.pop()
        for m in LINK.finditer(text):
            g = 2 if m.group(2) is not None else 3
            tail = text[m.start(g):m.end()]
            if "`" in tail:
                at = base + m.start(1) - 1   # the `[` itself
                ls = lines.start(at)   # a bisect: a line of many hits stays linear
                if code_free[at] == "[" and not _in_heading_span(
                        heads, prose, ls, at - ls, base + m.end(1) - ls):
                    yield base + m.start(g), tail
            pending.append((base + m.start(1), m.group(1)))


def _in_heading_span(heads, prose, ls, opener, closer):
    """True when the line starting at `ls` is an ATX heading (at any depth)
    and a code span of it covers column `opener` (the link's `[`) or column
    `closer` (its `]`). The spans of a line are found once, in `heads`, and
    placed by bisect, so a heading with many links stays linear."""
    if ls not in heads:
        eol = prose.find("\n", ls)
        line = prose[ls:eol if eol >= 0 else len(prose)]
        spans = _code_spans(line) if ATX_NESTED.match(line) else None
        heads[ls] = None if spans is None else ([x[0] for x in spans], spans)
    if heads[ls] is None:
        return False
    starts, spans = heads[ls]
    for col in (opener, closer):
        k = bisect.bisect_right(starts, col) - 1
        if k >= 0 and col < spans[k][1]:
            return True
    return False


def check_file(tree, rel):
    raw = read_text(tree.root, rel)
    lines = Lines(raw)
    line_of = lines.of
    found = []   # (line, target, error)
    is_md = rel.endswith(".md")
    blocks = strip_blocks(raw) if is_md else raw
    code_free = blank_spans(blocks, True) if is_md else raw
    for m in SELF.finditer(code_free):
        err = resolve(tree, "", m.group(1))
        if err:
            found.append((line_of(m.start()), m.group(0), err))
    if not is_md:
        return sorted(set(found))
    for off, tail in backtick_links(blank_spans(blocks, False), code_free, lines):
        found.append((line_of(off), tail, "a backtick in a link destination or "
                      "title cannot be told from a code span (write a "
                      "destination's backtick as %60, drop a title's)"))
    targets = []   # (offset, as written, as resolved)
    pending = [(0, code_free)]
    while pending:
        base, text = pending.pop()
        for m in LINK.finditer(text):
            g = 2 if m.group(2) is not None else 3
            targets.append((base + m.start(g), m.group(g), md_dest(m.group(g))))
            # An image inside a link (a badge) is a link of its own.
            pending.append((base + m.start(1), m.group(1)))
    labels = set()
    for m in REFDEF.finditer(code_free):
        labels.add(ref_label(m.group(1)))
        g = 2 if m.group(2) is not None else 3
        targets.append((m.start(g), m.group(g), md_dest(m.group(g))))
    for _, name, off, value in html_attrs(code_free):
        if name in ("href", "src"):
            targets.append((off, value, html_url(value)))
    for m in REFLINK.finditer(code_free):
        label = m.group(2) if m.group(2).strip() else m.group(1)
        if ref_label(label) not in labels:
            found.append((line_of(m.start()), "[%s]" % label,
                          "no such reference definition in this file"))
    for off, shown, t in targets:
        if SCHEME.match(t):
            continue   # external, or SELF above; never fetched
        err = resolve(tree, rel, t)
        if err:
            found.append((line_of(off), shown, err))
    return sorted(set(found))


def main(argv):
    root = os.path.realpath(argv[1] if len(argv) > 1 else ".")
    top = git(root, "rev-parse", "--show-toplevel").decode("utf-8", "surrogateescape").rstrip("\n")
    if os.path.realpath(top) != root:
        raise GateError("%s is not the toplevel of a git checkout (toplevel: %s)" % (root, top))
    tree = Tree(root)
    scanned = sorted(f for f in tree.modes
                     if tree.is_regular(f)
                     and (f.endswith(".md")
                          or re.match(r"^\.github/ISSUE_TEMPLATE/[^/]+\.ya?ml$", f)))
    if not scanned:
        raise GateError("no tracked Markdown files under %s - nothing to check" % root)
    bad = 0
    for rel in scanned:
        if os.path.islink(os.path.join(root, rel)) or not os.path.isfile(os.path.join(root, rel)):
            # Tracked as a regular file but missing, or swapped for a symlink,
            # in the working tree: the checkout is mid-edit.
            raise GateError("%s: tracked as a regular file but not one in the working tree" % rel)
        for line, target, err in check_file(tree, rel):
            print(tty_safe("%s:%d: %s: %s" % (rel, line, err, target)))
            bad += 1
    print("linkcheck: %d files, %d broken links" % (len(scanned), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except GateError as e:
        print(tty_safe("linkcheck: ERROR: %s - failing closed" % e), file=sys.stderr)
        sys.exit(2)
    except Exception as e:   # any bug in the gate is a failure, never a pass
        print(tty_safe("linkcheck: ERROR: %s: %s - failing closed" % (type(e).__name__, e)),
              file=sys.stderr)
        sys.exit(2)
