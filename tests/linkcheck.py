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
    reference definition `[ref]: path`, and the `href` or `src` of an HTML
    `<a>` or `<img>` tag (double- or single-quoted) must name a tracked
    file, or a directory holding one, inside ROOT. An inline link's
    destination is read up to 2048 characters: a longer one is not a link
    to this gate (no file name in a git tree comes close). An untracked
    file on this machine does not count: GitHub
    renders the tracked tree, so a link to a gitignored `.local` file is broken
    there even though it resolves here. Case is compared exactly for the same
    reason (a case-insensitive APFS resolves `Docs/` where GitHub does not). A
    `?query` is dropped before resolving;
  - a full or collapsed reference link, `[text][ref]` or `[text][]`, must have
    a matching definition in the same file (labels compared case-folded, with
    whitespace collapsed). A shortcut `[ref]` is not checked: it cannot be told
    apart from bracketed prose;
  - an `#anchor` into a Markdown file must match one of its headings under
    GitHub's slug rule (see slugify), repeats numbered -1, -2 the way
    github-slugger numbers them, or an explicit `<a id="...">` /
    `<a name="...">`. An anchor into any other file (a `#L10` line anchor), or
    into a tracked symlink, is not checked;
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
CommonMark's 999 characters, a destination, a title or an `<a>` id at 2048)
or stops at the next opener of its kind; everything else is a str.find loop
or a lookup built in one pass. An HTML attribute value is read up to its
closing quote by str.find, so it has no length cap.

Exit: 0 every link resolves; 1 a broken link (each printed as
FILE:LINE: reason: target, in sorted file order); 2 the gate itself could not
run (not a git toplevel, git failed or warned, an unreadable or non-UTF-8
file, a file reached through a symlink swapped into the working tree, any
unexpected error). Exit 2 is never a pass. Every printed line goes
through tty_safe, since it echoes names and text from the scanned tree.

Python 3.9-safe: macOS's Command Line Tools python3 is 3.9.
"""

import bisect
import os
import re
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
# `<a ... id="x">` (or name=): the attributes before it are read lazily, at
# most 2048 characters and never past the next `<`, so a line of `<a `
# openers costs each one the stretch up to the next.
EXPLICIT = re.compile(r"<a(?=\s)[^<>]{0,2048}?(?<=\s)(?:id|name)=\"([^\"]{1,2048})\"")
# [text](dest "title"): text may wrap across lines (never across a blank
# line) and may hold one level of nested brackets, which covers an image
# inside a link (a badge). The destination is bounded and ATOMIC (a
# lookahead captures it, a backreference consumes it, so it is never
# backtracked into): unbounded, every `[a](b` on a line of them rescanned
# the rest of the line. Nothing it could give back would let the match
# succeed, since a destination never holds what may follow it.
TEXT = r"((?:[^\[\]\n]|\n(?![ \t]*\n)|\[[^\[\]]*\])*)"
LINK = re.compile(r"(?<!\\)\[" + TEXT + r"\]\(\s*<?(?=([^)\s>]{1,2048}))\2>?"
                  r"(?:\s+\"[^\"]{0,2048}\")?\s*\)")
REFLINK = re.compile(r"(?<![\\\]])\[" + TEXT + r"\]\[([^\[\]]*)\]")
# A definition's label holds no unescaped bracket and at most 999 characters
# (CommonMark): unbounded, each line opening with `[` scanned the rest of the
# file for a `]`.
REFDEF = re.compile(r"^ {0,3}\[([^\[\]]{1,999})\]:[ \t]*<?(\S+?)>?(?:[ \t].*)?$", re.M)
# An `<a` or `<img` tag opener; its attributes are read up to the tag's own
# `>` (found with str.find, so an unclosed tag costs one scan, not one per
# opener). HTML_ATTR finds where an href or src value opens, and str.find
# its closing quote (double or single) inside the tag.
HTML_TAG = re.compile(r"<(?:a|img)(?=[\s>/])", re.I)
HTML_ATTR = re.compile(r"\s(?:href|src)\s*=\s*([\"'])", re.I)
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
BLANK_LINE = re.compile(r"\n[ \t]*\n")
MODE_SYMLINK, MODE_GITLINK = "120000", "160000"
# Printable, yet they reorder or hide what a terminal shows: the Arabic
# letter mark, the zero-width space and joiners, the LRM and RLM marks, the
# line and paragraph separators, the bidi embeddings and overrides, the bidi
# isolates, and the zero-width no-break space (BOM).
BIDI_HIDDEN = frozenset(
    [chr(0x061C), chr(0xFEFF)]
    + [chr(c) for c in range(0x200B, 0x2010)]
    + [chr(c) for c in range(0x2028, 0x202F)]
    + [chr(c) for c in range(0x2066, 0x206A)])


class GateError(Exception):
    """The gate could not do its job: exit 2, never a pass."""


def tty_safe(s):
    """Escape what a terminal would act on, the rule bin/check-patterns'
    sanitizer applies: C0 controls but TAB, DEL, and C1 (U+0080 to U+009F),
    printed as `\\xHH`. LF is escaped too, since each report is one line and
    a name holding one would forge a second. A byte that was not UTF-8
    (decoded with surrogateescape) prints as its `\\xHH` as well. Beyond
    that rule, the characters that reorder or hide text without being
    controls (BIDI_HIDDEN) print as `\\uHHHH`, so a report cannot show one
    target while naming another."""
    out = []
    for ch in s:
        o = ord(ch)
        if 0xDC80 <= o <= 0xDCFF:
            out.append("\\x%02x" % (o - 0xDC00))
        elif (o < 0x20 and ch != "\t") or 0x7F <= o <= 0x9F:
            out.append("\\x%02x" % o)
        elif ch in BIDI_HIDDEN:
            out.append("\\u%04x" % o)
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
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        raise GateError("%s: %s" % (rel, e.strerror))
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
    return blank_spans(("\n".join(out)), spans)


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
    per paragraph; and the next `<!--` is searched again only once the scan
    has passed it (a file with none answers -1 once, not once per run)."""
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
    while i < n:
        if 0 <= c < i:
            c = text.find("<!--", i)
        while r < len(runs) and runs[r][0] < i:
            r += 1
        a = runs[r][0] if r < len(runs) else -1
        if a < 0 and c < 0:
            break
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


# A link inside a heading, for slugify: it renders as its text. The destination
# follows CommonMark: no whitespace; a backslash escapes only ASCII punctuation
# (`\(` and `\)` included), else it is a literal; balanced parentheses nest;
# or `<...>`, which may hold spaces. A quoted or parenthesized title may follow.
# Nesting stops at 3 levels: GitHub's cmark-gfm allows 32 (inlines.c), but a
# heading link deeper than 3 is far past anything in a tracked doc, and a
# deeper one stays literal text here (pinned by a test) instead of a hang risk.
# Linear time: the alternatives of the starred group start on different
# characters (a lookahead splits the two backslash forms), and the optional
# group holds the whole destination-title-spaces tail, so a run of spaces has
# one way to be consumed.
_PUNCT = r"[!-/:-@\[-`{-~]"
_DEST_CHAR = r"\\" + _PUNCT + r"|\\(?!" + _PUNCT + r")|[^()\\\s]"
_NEST = r"\((?:" + _DEST_CHAR + r")*\)"
for _ in range(2):
    _NEST = r"\((?:" + _DEST_CHAR + r"|" + _NEST + r")*\)"
HEADING_IMAGE = re.compile(r"!\[[^\[\]]*\]\((?:" + _DEST_CHAR + r"|" + _NEST + r")*\)")
HEADING_LINK = re.compile(
    r"\[([^\[\]]*)\]\(\s*(?:(?:<[^<>\n]*>|(?:" + _DEST_CHAR + r"|" + _NEST + r")+)"
    r"(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^()]*\)))?\s*)?\)")


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
    text = HEADING_IMAGE.sub("\0", text.strip())
    text = HEADING_LINK.sub(r"\1", text)   # a link renders as its text
    rendered, pos = [], 0
    for m in re.finditer(r"(?<!`)(`+)(?!`)(.{1,2048}?)(?<!`)\1(?!`)", text):
        rendered.append(_render_inline(text[pos:m.start()]))
        rendered.append(m.group(2))
        pos = m.end()
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
            text = strip_code(read_text(self.root, rel), spans=False)
            lines = text.split("\n")
            slugger, res = Slugger(), set()
            for i, ln in enumerate(lines):
                for m in EXPLICIT.finditer(ln):
                    res.add(m.group(1))
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
    targets = []
    pending = [(0, code_free)]
    while pending:
        base, text = pending.pop()
        for m in LINK.finditer(text):
            targets.append((base + m.start(2), m.group(2)))
            # An image inside a link (a badge) is a link of its own.
            pending.append((base + m.start(1), m.group(1)))
    labels = set()
    for m in REFDEF.finditer(code_free):
        labels.add(ref_label(m.group(1)))
        targets.append((m.start(2), m.group(2)))
    gt = -1
    for m in HTML_TAG.finditer(code_free):
        if m.start() < gt:
            continue   # inside the previous tag, so an attribute, not a tag
        gt = code_free.find(">", m.end())
        if gt < 0:
            break   # no later tag can close either
        pos = m.end()
        while True:
            a = HTML_ATTR.search(code_free, pos, gt)
            if not a:
                break
            close = code_free.find(a.group(1), a.end(), gt)
            if close < 0:
                pos = a.end()   # unclosed inside the tag: not a value; look on
                continue
            targets.append((a.end(), code_free[a.end():close]))
            pos = close + 1
    for m in REFLINK.finditer(code_free):
        label = m.group(2) if m.group(2).strip() else m.group(1)
        if ref_label(label) not in labels:
            found.append((line_of(m.start()), "[%s]" % label,
                          "no such reference definition in this file"))
    for off, t in targets:
        if SCHEME.match(t):
            continue   # external, or SELF above; never fetched
        err = resolve(tree, rel, t)
        if err:
            found.append((line_of(off), t, err))
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
