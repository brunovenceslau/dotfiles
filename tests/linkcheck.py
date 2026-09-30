# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""linkcheck - the `make linkcheck` gate: every in-repo link in the docs resolves.

Usage: python3 -I tests/linkcheck.py [ROOT]    (ROOT default: the current directory)

ROOT must be the toplevel of a git checkout. The scanned set is what git
TRACKS there, never a directory walk: every `*.md` file, plus the issue-form
YAML under .github/ISSUE_TEMPLATE/, which holds absolute links back into this
repository. Each link is checked against that same tracked set:

  - a relative Markdown link `[text](path#anchor)`, an image, and a reference
    definition `[ref]: path` must name a tracked file, or a directory holding
    one, inside ROOT. An untracked file on this machine does not count: GitHub
    renders the tracked tree, so a link to a gitignored `.local` file is broken
    there even though it resolves here. Case is compared exactly for the same
    reason (a case-insensitive APFS resolves `Docs/` where GitHub does not);
  - an `#anchor` into a Markdown file must match one of its headings under
    GitHub's slug rule (see slugify), duplicates numbered -1, -2 in document
    order, or an explicit `<a id="...">` / `<a name="...">`. An anchor into
    any other file (a `#L10` line anchor) is not checked;
  - an absolute `https://github.com/brunovenceslau/dotfiles/(blob|tree)/main/`
    link is resolved against the local tree the same way, in the YAML too.

Links inside fenced code blocks and inline code spans are not links and are
ignored. A link whose text wraps across lines is still found. External URLs
(any other scheme, `mailto:` included) are out of scope: this gate never
touches the network, so its answer depends only on the tree.

Exit: 0 every link resolves; 1 a broken link (each printed as
FILE:LINE: reason: target, in sorted file order); 2 the gate itself could not
run (not a git toplevel, git failed or warned, an unreadable or non-UTF-8
file, any unexpected error). Exit 2 is never a pass.

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
# at least as long.
FENCE = re.compile(r"^[ \t]*(`{3,}|~{3,})")
ATX = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$")
SETEXT = re.compile(r"^ {0,3}(=+|-+)[ \t]*$")
EXPLICIT = re.compile(r"<a\s+(?:[^>]*\s)?(?:id|name)=\"([^\"]+)\"")
# [text](dest "title"): text may wrap across lines (never across a blank
# line) and may hold one level of nested brackets, which covers an image
# inside a link (a badge).
LINK = re.compile(
    r"(?<!\\)\[((?:[^\[\]\n]|\n(?![ \t]*\n)|\[[^\[\]]*\])*)\]"
    r"\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
REFDEF = re.compile(r"^ {0,3}\[[^\]]+\]:[ \t]*<?(\S+?)>?(?:[ \t].*)?$", re.M)
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


class GateError(Exception):
    """The gate could not do its job: exit 2, never a pass."""


def git(root, *args):
    # stderr is part of the answer: git exits 0 and only WARNS when it drops
    # entries it cannot read, so a warning fails closed like an error.
    p = subprocess.run(["git", "-C", root] + list(args),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0 or p.stderr:
        raise GateError("git %s failed (exit %d): %s" % (
            " ".join(args), p.returncode, p.stderr.decode("utf-8", "replace").strip()))
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


def strip_code(text, spans=True):
    """Blank fenced blocks, front matter and (with spans) inline code spans.
    Headings keep their spans: GitHub's id includes a span's text."""
    lines = text.split("\n")
    out, fence = [], None
    if lines and lines[0] == "---":
        # YAML front matter (the .claude/rules pages): not rendered as prose.
        for i in range(1, len(lines)):
            if lines[i] == "---":
                out = [""] * (i + 1)
                lines = lines[i + 1:]
                break
    for ln in lines:
        m = FENCE.match(ln)
        if fence is None and m:
            fence = m.group(1)
            out.append("")
            continue
        if fence is not None:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) \
                    and ln.strip() == m.group(1):
                fence = None
            out.append("")
            continue
        out.append(ln)
    text = "\n".join(out)
    if not spans:
        return text
    # A code span opens with a run of N backticks and closes at the next run
    # of exactly N, possibly on a later line of the same paragraph.
    return re.sub(r"(?<!`)(`+)(?!`)((?:(?!\n[ \t]*\n).)*?[^`])\1(?!`)",
                  lambda m: blank(m.group(0)), text, flags=re.S)


def slugify(text):
    """GitHub's heading id: the rendered text, lowercased, with every character
    that is not a letter, mark, number, connector (`_`), hyphen or space
    dropped, and each space turned into `-`. No collapsing, no trimming of
    inner hyphens: `a - b` is `a---b`, as github-slugger makes it."""
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)   # a link renders as its text
    text = re.sub(r"<[^>]+>", "", text)                       # HTML tags render as nothing
    text = re.sub(r"(?<![\w])[*_]+|[*_]+(?![\w])", "", text)  # emphasis markers, not intra-word _
    text = text.replace("`", "").strip().lower()
    out = []
    for ch in text:
        cat = unicodedata.category(ch)
        if ch == " ":
            out.append("-")
        elif ch == "-" or cat[0] in "LMN" or cat == "Pc":
            out.append(ch)
    return "".join(out)


class Tree:
    def __init__(self, root):
        self.root = root
        self.files = set()
        self.dirs = {""}
        raw = git(root, "ls-files", "-z", "--cached")
        for f in raw.decode("utf-8", "surrogateescape").split("\0"):
            if not f:
                continue
            self.files.add(f)
            d = os.path.dirname(f)
            while d not in self.dirs:
                self.dirs.add(d)
                d = os.path.dirname(d)
        self._anchors = {}

    def anchors(self, rel):
        if rel not in self._anchors:
            text = strip_code(read_text(os.path.join(self.root, rel), rel), spans=False)
            lines = text.split("\n")
            seen, res = {}, set()
            for i, ln in enumerate(lines):
                for m in EXPLICIT.finditer(ln):
                    res.add(m.group(1))
                heading = None
                m = ATX.match(ln)
                if m:
                    heading = m.group(2) or ""
                elif i + 1 < len(lines) and ln.strip() and SETEXT.match(lines[i + 1]) \
                        and not ATX.match(ln) and not FENCE.match(ln):
                    # A setext heading: text underlined by === or ---. A `---`
                    # under a blank line is a thematic break, excluded by the
                    # ln.strip() test.
                    heading = ln.strip()
                if heading is None:
                    continue
                base = slugify(heading)
                n = seen.get(base, 0)
                res.add(base if n == 0 else "%s-%d" % (base, n))
                seen[base] = n + 1
            self._anchors[rel] = res
        return self._anchors[rel]


def resolve(tree, src_rel, target):
    """Return an error string for a broken target, or None."""
    path, _, frag = target.partition("#")
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
    if dest not in tree.files and dest not in tree.dirs:
        return "no such tracked file or directory"
    if frag and dest in tree.files and dest.endswith(".md") and frag not in tree.anchors(dest):
        return "no such anchor in %s" % dest
    return None


def line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def check_file(tree, rel):
    raw = read_text(os.path.join(tree.root, rel), rel)
    found = []   # (line, target, error)
    code_free = strip_code(raw) if rel.endswith(".md") else raw
    for m in SELF.finditer(code_free):
        err = resolve(tree, "", m.group(1))
        if err:
            found.append((line_of(raw, m.start()), m.group(0), err))
    if rel.endswith(".md"):
        targets = []
        pending = [(0, code_free)]
        while pending:
            base, text = pending.pop()
            for m in LINK.finditer(text):
                targets.append((base + m.start(2), m.group(2)))
                # An image inside a link (a badge) is a link of its own.
                pending.append((base + m.start(1), m.group(1)))
        for m in REFDEF.finditer(code_free):
            targets.append((m.start(1), m.group(1)))
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
    scanned = sorted(f for f in tree.files
                     if f.endswith(".md")
                     or re.match(r"^\.github/ISSUE_TEMPLATE/[^/]+\.ya?ml$", f))
    if not scanned:
        raise GateError("no tracked Markdown files under %s - nothing to check" % root)
    bad = 0
    for rel in scanned:
        if not os.path.isfile(os.path.join(root, rel)):
            # Tracked but deleted in the working tree: the checkout is mid-edit.
            raise GateError("%s: tracked but missing from the working tree" % rel)
        for line, target, err in check_file(tree, rel):
            print("%s:%d: %s: %s" % (rel, line, err, target))
            bad += 1
    print("linkcheck: %d files, %d broken links" % (len(scanned), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except GateError as e:
        print("linkcheck: ERROR: %s - failing closed" % e, file=sys.stderr)
        sys.exit(2)
    except Exception as e:   # any bug in the gate is a failure, never a pass
        print("linkcheck: ERROR: %s: %s - failing closed" % (type(e).__name__, e), file=sys.stderr)
        sys.exit(2)
