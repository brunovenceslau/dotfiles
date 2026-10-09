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
    (3 levels deep), backslash escapes of ASCII punctuation, or the `<...>`
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
    reads an HTML block (HTML_OPEN names the known misses): a `>` inside a
    quoted value does not end it, and one that crosses a blank line is text,
    so a tag inside it is still found;
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
never past a blank line), or crosses at most 3 later openers (a link
destination, since each opener brings an unclosed parenthesis and a 4th
level ends it); everything else is a str.find loop or a lookup built in
one pass. No destination, title or attribute value has a length limit:
each of the others was bounded once, which silently skipped a long link,
and the test's hostile shapes, measured at 800 KB each, run in well under
a second without one. HTML_OPEN says why an open tag's scan stays linear.

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
SETEXT = re.compile(r"^ {0,3}(=+|-+)[ \t]*$")
# A line break that is not a blank line, and the whitespace that may sit
# between the parts of a link or a tag: never a blank line (a paragraph,
# and an HTML block, ends there), and ASCII only. Python's `\s` also
# matches U+00A0, U+0085 and U+2028, which CommonMark reads as ordinary
# characters inside a destination.
_PARA = r"\n(?![ \t]*\n)"
_WS = r"(?:[ \t\r\f\v]|" + _PARA + r")"
# A link destination follows CommonMark, in the body and in a heading alike:
# no ASCII whitespace; a backslash escapes only ASCII punctuation (`\(` and
# `\)` included), else it is a literal; balanced parentheses nest; it never
# starts with `<`, since that opens the other form, `<...>`, which may hold
# spaces and an escaped `\>`.
# Nesting stops at 3 levels: GitHub's cmark-gfm allows 32 (inlines.c), but a
# destination deeper than 3 is far past anything in a tracked doc, and a
# deeper one is not read as a link here (pinned by a test) instead of a hang
# risk. Linear time: the alternatives of every starred group start on
# different characters (a lookahead splits the two backslash forms), so a
# string splits into units one way only and a failed match gives each
# position back once.
_PUNCT = r"[!-/:-@\[-`{-~]"
_DEST_CHAR = r"\\" + _PUNCT + r"|\\(?!" + _PUNCT + r")|[^()\\ \t\n\r\f\v]"
_NEST = r"\((?:" + _DEST_CHAR + r")*\)"
for _ in range(2):
    _NEST = r"\((?:" + _DEST_CHAR + r"|" + _NEST + r")*\)"
_DEST_BARE = r"(?!<)(?:" + _DEST_CHAR + "|" + _NEST + r")+"
_DEST_ANGLE = r"<((?:[^<>\n\\]|\\[^\n])*)>"
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
# (`<...>`, without its brackets) or 3 (bare). The bare form is ATOMIC (a
# lookahead captures it, a backreference consumes it, so it is never
# backtracked into): nothing it could give back would let the match
# succeed, since a destination never ends where a dest character follows.
TEXT = r"((?:" + _span_char(r"\[\]") + r"|\[" + _LABEL_CHAR + r"*\])*)"
_TITLE = (r"(?:\"(?:" + _span_char(r"\"") + r")*\"|'(?:" + _span_char("'") + r")*'"
          r"|\((?:" + _span_char(r"()") + r")*\))")
LINK = re.compile(_OPEN + TEXT + r"\]\(" + _WS + r"*(?:" + _DEST_ANGLE
                  + r"|(?=(" + _DEST_BARE + r"))\3)(?:" + _WS + r"+" + _TITLE + r")?"
                  + _WS + r"*\)")
REFLINK = re.compile(r"(?<!\])" + _OPEN + TEXT + r"\]\[(" + _LABEL_CHAR + r"*)\]")
# A definition (CommonMark 4.7): a label of at most 999 characters (an
# escape pair counts as one here, so the bound is loose by at most half;
# unbounded, each line opening with `[` scanned the rest of the file for a
# `]`), a colon, the destination on the same line or the next (group 2 a
# `<...>` one, group 3 a bare one), and an optional title after whitespace,
# itself on the same line or the next. Only spaces may follow on its last
# line; a title that fails that leaves the definition ending at the
# destination, and anything else after the destination is no definition.
REFDEF = re.compile(r"^ {0,3}\[(" + _LABEL_CHAR + r"{1,999})\]:[ \t]*(?:\n[ \t]*)?(?:"
                    + _DEST_ANGLE + r"|(?=(" + _DEST_BARE + r"))\3)(?:(?:[ \t]+|[ \t]*\n[ \t]*)"
                    + _TITLE + r"[ \t]*$|[ \t]*$)", re.M)
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
# html_attrs walks the attributes of a matched tag with HTML_ATTR.
# Linear: a name, a bare value and a quoted value start on different
# characters, and a name follows whitespace and `/` or a closing quote only,
# so a tag parses one way only; a `<` outside a quoted value or a name ends
# an opener's scan, and an opener inside another's quoted value runs on only
# through a value of the other quote kind, so scans overlap at most two deep.


def _hattr(group):
    """One attribute after its separator; group is "(" to capture the name
    and the value (2 double-quoted, 3 single-quoted, 4 bare), "(?:" for
    the copy inside HTML_OPEN. A name followed by `=` takes a value (the
    lookahead), else `a =b` would parse as `a=b` and as `a`, `=b`."""
    value = (r"(?:\"" + group + r"(?:[^\"\n]|" + _PARA + r")*)\"|'" + group
             + r"(?:[^'\n]|" + _PARA + r")*)'|" + group + r"[^ \t\n\r\f\v\"'<>]+))")
    plain = r"[^ \t\n\r\f\v\"'=<>/]"
    name = (r"(?:=|" + plain + r")(?:" + plain + r"|<(?!(?i:a|img)[ \t\n\r\f\v/>]))*")
    return (r"(?:(?:" + _WS + r"|/)+|(?<=[\"']))" + group + name + r")(?:"
            + _WS + r"*=" + _WS + r"*" + value + r"|(?!" + _WS + r"*=))")


HTML_ATTR = re.compile(_hattr("("))
HTML_OPEN = re.compile(r"<(a|img)((?:" + _hattr("(?:") + r")*)" + _WS + r"*/?>", re.I)
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


def strip_code(text, spans=True):
    """Blank what is not prose: front matter, fenced and indented code blocks,
    HTML comments, and (with spans) inline code spans. Every blanked character
    becomes a space, so offsets and line numbers still point into the file.
    Headings are read with spans=False: GitHub's id includes a span's text."""
    return blank_spans(strip_blocks(text), spans)


def strip_blocks(text):
    """The block-level half of strip_code: front matter and code blocks."""
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
    tag = HTML_OPEN.search(text) if spans else None
    t = tag.start() if tag else -1
    while i < n:
        if 0 <= c < i:
            c = text.find("<!--", i)
        if 0 <= t < i:
            tag = HTML_OPEN.search(text, i)
            t = tag.start() if tag else -1
        while r < len(runs) and runs[r][0] < i:
            r += 1
        a = runs[r][0] if r < len(runs) else -1
        if a < 0 and c < 0 and t < 0:
            break
        if t >= 0 and (a < 0 or t < a) and (c < 0 or t < c):
            pieces.append(text[i:tag.end()])
            i = tag.end()
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


def _render_inline(s):
    """Rendered text of a heading fragment that holds no code span."""
    parts = re.split(r"\\([!-/:-@\[-`{-~])", s)   # odd items: backslash-escaped chars
    out = []
    for k, p in enumerate(parts):
        if k % 2:
            out.append(p)   # an escaped `_` or `*` is a literal, never emphasis
        else:
            p = re.sub(r"<[^<>]+>", "", p)                        # HTML tags render as nothing
            p = re.sub(r"(?<![\w])[*_]+|[*_]+(?![\w])", "", p)    # emphasis, not intra-word _
            out.append(p)
    return "".join(out)


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
# destination and title (the rules above LINK). The optional group holds
# the whole destination-title-spaces tail, so a run of spaces is retried at
# most once per part, never once per start position.
_TAIL = (r"\(" + _WS + r"*(?:(?:" + _DEST_ANGLE + "|" + _DEST_BARE + r")"
         r"(?:" + _WS + r"+" + _TITLE + r")?" + _WS + r"*)?\)")
# An image shares the link's tail, else the `[alt](...)` part of an image with
# a title would match as a link and leak its alt text; an escaped `!` makes it
# a plain link.
HEADING_IMAGE = re.compile(r"(?<!\\)!\[([^\[\]]*)\]" + _TAIL)
HEADING_LINK = re.compile(r"\[([^\[\]]*)\]" + _TAIL)


# A code span in one line: N backticks up to the next run of exactly N. A
# backslash escape is consumed first (alternative 1), so an escaped backtick
# opens nothing; inside a span backslashes are literal, and the span's
# content is consumed whole, so they are never seen as escapes.
_SPAN = re.compile(r"\\[!-/:-@\[-`{-~]|(?<!`)(`+)(?!`)(.{1,2048}?)(?<!`)\1(?!`)")


def _code_spans(text):
    """[(start, end, content)] of the code spans of one line. A span binds
    tighter than link syntax (CommonMark 6.1) except where a link's
    destination or title holds the backtick: `[a](u`) `b`` is a link and a
    span, not a span over `) `. So the spans are found once, a link or
    image that opens outside them, with no span opening in its text (that span
    takes the `](`: `[`a](u`)` is `a](u` in code), marks its destination and
    title as a zone where no backtick opens or closes anything, and they are
    found again with the zones hidden."""
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
            j = k + 1
            if j < len(starts) and starts[j] < m.end(1):
                continue   # a span opens in its text and takes the `](`
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
    text = _sub_outside_spans(HEADING_LINK, lambda m, t: t[m.start(1):m.end(1)], text)
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
    text = "".join(rendered).strip().lower()
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
    `<a>` or `<img>` open tag, tag and name lowercased. The attributes tile
    HTML_OPEN's group 2 with no gap, one parse only, so HTML_ATTR's walk is
    the parse HTML_OPEN matched."""
    for m in HTML_OPEN.finditer(text):
        tag = m.group(1).lower()
        for a in HTML_ATTR.finditer(text, m.start(2), m.end(2)):
            for g in (2, 3, 4):
                if a.group(g) is not None:
                    yield tag, a.group(1).lower(), a.start(g), a.group(g)
                    break


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


def check_file(tree, rel):
    raw = read_text(tree.root, rel)
    line_of = Lines(raw).of
    found = []   # (line, target, error)
    is_md = rel.endswith(".md")
    code_free = strip_code(raw) if is_md else raw
    for m in SELF.finditer(code_free):
        err = resolve(tree, "", m.group(1))
        if err:
            found.append((line_of(m.start()), m.group(0), err))
    if not is_md:
        return sorted(set(found))
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
