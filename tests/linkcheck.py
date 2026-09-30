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
    `<a>` or `<img>` tag (double- or single-quoted) must name a tracked file, or a directory holding one,
    inside ROOT. An untracked file on this machine does not count: GitHub
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
as a rule and the rest as prose, so its links are checked. A CR before a LF
is not part of a line. A link whose text wraps across lines is still found. External
URLs (any other scheme, `mailto:` included) are out of scope: this gate never
touches the network, so its answer depends only on the tree.

Exit: 0 every link resolves; 1 a broken link (each printed as
FILE:LINE: reason: target, in sorted file order); 2 the gate itself could not
run (not a git toplevel, git failed or warned, an unreadable or non-UTF-8
file, any unexpected error). Exit 2 is never a pass. Every printed line goes
through tty_safe, since it echoes names and text from the scanned tree.

Python 3.9-safe: macOS's Command Line Tools python3 is 3.9.
"""

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
ATX = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$")
SETEXT = re.compile(r"^ {0,3}(=+|-+)[ \t]*$")
EXPLICIT = re.compile(r"<a\s+(?:[^>]*\s)?(?:id|name)=\"([^\"]+)\"")
# [text](dest "title"): text may wrap across lines (never across a blank
# line) and may hold one level of nested brackets, which covers an image
# inside a link (a badge).
TEXT = r"((?:[^\[\]\n]|\n(?![ \t]*\n)|\[[^\[\]]*\])*)"
LINK = re.compile(r"(?<!\\)\[" + TEXT + r"\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
REFLINK = re.compile(r"(?<![\\\]])\[" + TEXT + r"\]\[([^\[\]]*)\]")
REFDEF = re.compile(r"^ {0,3}\[([^\]]+)\]:[ \t]*<?(\S+?)>?(?:[ \t].*)?$", re.M)
# An `<a` or `<img` tag opener; its attributes are read up to the tag's own
# `>` (found with str.find, so an unclosed tag costs one scan, not one per
# opener), and a value may be double- or single-quoted.
HTML_TAG = re.compile(r"<(?:a|img)(?=[\s>/])", re.I)
# A value is capped at 2048 characters, so an unclosed quote scans a bounded
# stretch rather than the rest of the tag once per attribute.
HTML_ATTR = re.compile(r"\s(?:href|src)\s*=\s*(?:\"([^\"]{0,2048})\"|'([^']{0,2048})')", re.I)
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
BLANK_LINE = re.compile(r"\n[ \t\r]*\n")
MODE_SYMLINK, MODE_GITLINK = "120000", "160000"


class GateError(Exception):
    """The gate could not do its job: exit 2, never a pass."""


def tty_safe(s):
    """Escape what a terminal would act on, the rule bin/check-patterns'
    sanitizer applies: C0 controls but TAB, DEL, and C1 (U+0080 to U+009F),
    printed as `\\xHH`. LF is escaped too, since each report is one line and
    a name holding one would forge a second. A byte that was not UTF-8
    (decoded with surrogateescape) prints as its `\\xHH` as well."""
    out = []
    for ch in s:
        o = ord(ch)
        if 0xDC80 <= o <= 0xDCFF:
            out.append("\\x%02x" % (o - 0xDC00))
        elif (o < 0x20 and ch != "\t") or 0x7F <= o <= 0x9F:
            out.append("\\x%02x" % o)
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


def read_text(path, rel):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        raise GateError("%s: %s" % (rel, e.strerror))
    try:
        return data.decode("utf-8")
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
    if lines and lines[0].rstrip("\r") == "---":
        # YAML front matter (the .claude/rules pages): not rendered as prose.
        for j in range(1, len(lines)):
            if lines[j].rstrip("\r") == "---":
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
    of the file, as an HTML block does. Every search is a str.find from the
    current position, and a paragraph's end is found once per paragraph, so
    hostile input (many openers, none closed) stays near-linear."""
    n = len(text)
    ends = [m.start() for m in BLANK_LINE.finditer(text)] + [n]
    pieces, i, e = [], 0, 0
    while i < n:
        a = text.find("`", i)
        c = text.find("<!--", i)
        if a < 0 and c < 0:
            break
        if c >= 0 and (a < 0 or c < a):
            close = text.find("-->", c + 4)
            end = n if close < 0 else close + 3
            pieces.append(text[i:c])
            pieces.append(blank(text[c:end]))
            i = end
            continue
        k = a
        while k < n and text[k] == "`":
            k += 1
        run = k - a
        while ends[e] < a:
            e += 1
        limit = ends[e]
        j, close = k, -1
        while True:
            j = text.find("`" * run, j, limit)
            if j < 0:
                break
            r = j + run
            while r < n and text[r] == "`":
                r += 1
            if r - j == run:
                close = j
                break
            j = r   # a longer run: skip all of it
        if close < 0:
            pieces.append(text[i:k])   # an unmatched run is literal backticks
            i = k
            continue
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
            p = re.sub(r"<[^>]+>", "", p)                         # HTML tags render as nothing
            p = re.sub(r"(?<![\w])[*_]+|[*_]+(?![\w])", "", p)    # emphasis, not intra-word _
            out.append(p)
    return "".join(out)


def slugify(text):
    """GitHub's heading id: the rendered text, lowercased, with every character
    that is not a letter, mark, number, connector (`_`), hyphen or space
    dropped, and each space turned into `-`. No collapsing, no trimming of
    inner hyphens: `a - b` is `a---b`, as github-slugger makes it. A code
    span renders verbatim, so emphasis and escape rules stop at its edges:
    `_link_bin_tree` keeps both underscores."""
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)   # a link renders as its text
    rendered, pos = [], 0
    for m in re.finditer(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)", text):
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
            text = strip_code(read_text(os.path.join(self.root, rel), rel), spans=False)
            lines = [ln.rstrip("\r") for ln in text.split("\n")]
            slugger, res = Slugger(), set()
            for i, ln in enumerate(lines):
                for m in EXPLICIT.finditer(ln):
                    res.add(m.group(1))
                heading = None
                m = ATX.match(ln)
                if m:
                    heading = m.group(2) or ""
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


def line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def check_file(tree, rel):
    raw = read_text(os.path.join(tree.root, rel), rel)
    found = []   # (line, target, error)
    is_md = rel.endswith(".md")
    code_free = strip_code(raw) if is_md else raw
    for m in SELF.finditer(code_free):
        err = resolve(tree, "", m.group(1))
        if err:
            found.append((line_of(raw, m.start()), m.group(0), err))
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
        for a in HTML_ATTR.finditer(code_free, m.end() - 1, gt):
            g = 1 if a.group(1) is not None else 2
            targets.append((a.start(g), a.group(g)))
    for m in REFLINK.finditer(code_free):
        label = m.group(2) if m.group(2).strip() else m.group(1)
        if ref_label(label) not in labels:
            found.append((line_of(raw, m.start()), "[%s]" % label,
                          "no such reference definition in this file"))
    for off, t in targets:
        if SCHEME.match(t):
            continue   # external, or SELF above; never fetched
        err = resolve(tree, rel, t)
        if err:
            found.append((line_of(raw, off), t, err))
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
