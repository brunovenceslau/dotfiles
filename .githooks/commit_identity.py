# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""commit_identity - refuse a commit identity set inside the repository.

Usage: python3 -I .githooks/commit_identity.py pre-commit|pre-push|check

Exits 1 when an identity key (`email` or `name` under `user`, `author` or
`committer`) is set at git config scope `local` (the repository's shared
config, `.git/config`, or a file it includes) or `worktree`
(`config.worktree`, when extensions.worktreeConfig is on). A
`git config user.email ...` run inside a linked worktree lands in the SHARED
`.git/config`, so every worktree of the repository then commits under that
identity, signed by the right key but authored by the wrong person.
`author.*` and `committer.*` count too: they set the identity as well, and a
repository-scoped `author.email` even wins over `git -c user.email=...`.

`pre-push` also refuses a pushed commit whose author or committer email
differs from the effective identity (`git var GIT_AUTHOR_IDENT` and
`GIT_COMMITTER_IDENT` at push time, so a `git -c user.email=...` on the push
counts). This is what catches an identity removed from the config before the
push: the commits made under it still carry it. The commits compared are
those reachable from a pushed tip but from no remote-tracking ref (of any
remote) and from no remote oid git names on stdin. A commit already fetched
from a remote passes whoever made it, so merging a fetched default branch
does not trip on GitHub's own merge commits; one the remote holds under a
ref never fetched is still compared. A foreign author is refused on
purpose: `git push --no-verify` is the escape for a reviewed commit made by
someone else. While a config refusal stands the commits are not compared:
the effective identity is then the polluted one.

A guardrail against accidents, not an enforcement boundary: merge, rebase
and cherry-pick skip pre-commit, and `--no-verify` or a repository
core.hooksPath skips both hooks.

Allowed, by design: `git -c user.email=...` per command (scope `command`,
GIT_CONFIG_COUNT included; the recipe for a scratch commit), the
GIT_AUTHOR_* and GIT_COMMITTER_* variables (not config at all), and the
global and system scopes. Nothing else is checked: no trust root, no
signature, no allowed-signers lookup.

The argument names the caller, for the message. `pre-push` reads every ref
line git writes on stdin before anything else, so git never meets a closed
pipe on a large push. A deletion pushes no commit and needs no identity.

Exits 2 when it cannot answer (not a repository, git failing, a ref line of
an unexpected shape, no effective identity while there are commits to
compare), never 0.

Self-contained on purpose: it runs from a git hook in any checkout of this
repository, so it imports nothing from lib/ and only the standard library,
and `-I` keeps the current directory off sys.path.
"""

import os
import shlex
import subprocess
import sys

SECTIONS = ("user", "author", "committer")
KEYS = tuple("%s.%s" % (s, k) for s in SECTIONS for k in ("email", "name"))
KEYS_REGEXP = r"^(%s)\.(email|name)$" % "|".join(SECTIONS)
REFUSED_SCOPES = ("local", "worktree")
IDENTS = (("author", "GIT_AUTHOR_IDENT"), ("committer", "GIT_COMMITTER_IDENT"))
HEX = frozenset("0123456789abcdef")
CALLERS = ("pre-commit", "pre-push", "check")
PREFIX = "commit-identity"


def escape(s):
    """One printable line: a backslash doubles, and a character that is not
    printable (a control, LF, a bidi or zero-width format character, a byte
    that was not UTF-8) prints as its escape, so a value cannot forge a
    second line or hide part of the message."""
    out = []
    for ch in s:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif 0xDC80 <= o <= 0xDCFF:
            out.append("\\x%02x" % (o - 0xDC00))
        elif ch.isprintable():
            out.append(ch)
        elif o <= 0xFF:
            out.append("\\x%02x" % o)
        elif o <= 0xFFFF:
            out.append("\\u%04x" % o)
        else:
            out.append("\\U%08x" % o)
    return "".join(out)


def quoted(s):
    """s escaped and in single quotes, a quote inside it spelled \\x27, so
    a value cannot close its quotes and add a "fix:" of its own. The
    backslash escape() doubles keeps \\x27 from being read back as one."""
    return "'%s'" % escape(s).replace("'", "\\x27")


def decode(b):
    return b.decode("utf-8", "surrogateescape")


def fail(msg):
    print("%s: %s" % (PREFIX, escape(msg)), file=sys.stderr)
    sys.exit(2)


def git_failed(what, p, why=None):
    """Exit 2 naming a git command, its exit code and, when it said one,
    why: `why` when given, else its whole stderr."""
    if why is None:
        why = decode(p.stderr).strip()
    fail("%s failed (exit %d)%s" % (what, p.returncode,
                                    ": " + why if why else ""))


def git_env(gdir):
    """The environment every git call here runs in. GIT_DIR is the absolute
    git dir (see entries()). GIT_NO_LAZY_FETCH keeps a partial clone from
    fetching a missing object over the network to answer a hook: a remote
    oid it lacks is skipped (--ignore-missing) instead. git 2.45 and later
    honour it, older ones ignore it."""
    return dict(os.environ, GIT_DIR=gdir, GIT_NO_LAZY_FETCH="1")


def git_dir():
    # Honours a GIT_DIR a hook inherits from git: that names the repository
    # being committed in, which is exactly the one to check.
    p = subprocess.run(["git", "rev-parse", "--absolute-git-dir"],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out = decode(p.stdout)
    if p.returncode != 0 or not out.endswith("\n") or "\n" in out[:-1]:
        git_failed("'git rev-parse --absolute-git-dir'", p)
    return out[:-1]


def entries(gdir):
    """Yield (scope, origin, key, value) for each identity key in KEYS.

    GIT_DIR is pinned to the ABSOLUTE git dir: git prints a repository
    origin relative to its own working directory otherwise (`.git/config`
    from a worktree, `config` from inside the git dir or a bare repository),
    and the fix this prints must name a file that exists from anywhere."""
    env = git_env(gdir)
    p = subprocess.run(
        ["git", "config", "--show-scope", "--show-origin", "-z",
         "--get-regexp", KEYS_REGEXP],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    # 1 is "no such key": nothing set anywhere is a pass.
    if p.returncode == 1 and not p.stdout:
        return
    if p.returncode != 0:
        git_failed("'git config'", p)
    # -z: each entry is SCOPE NUL ORIGIN NUL KEY LF VALUE NUL. A key with no
    # `=` at all (`[user] name`) would print no LF, but git refuses every
    # one of KEYS without a value ("missing value"), so git_dir()'s
    # rev-parse has already failed on it: an entry without the LF is an
    # unexpected shape, not a case to format.
    fields = p.stdout.split(b"\0")
    if fields[-1] != b"" or (len(fields) - 1) % 3:
        fail("'git config -z' printed an unexpected shape")
    for i in range(0, len(fields) - 1, 3):
        key, sep, value = fields[i + 2].partition(b"\n")
        if not sep:
            fail("'git config -z' printed a key without a value")
        yield (decode(fields[i]), decode(fields[i + 1]), decode(key),
               decode(value))


def origin_file(origin):
    """The path of the config file an origin names, or None (`command line:`,
    `blob:`, `standard input:`). The path is returned as git printed it: with
    GIT_DIR absolute, git 2.26 and later print an absolute one, and a
    relative one is never resolved here (a join or normpath could name
    another file, `..` through a symlink)."""
    kind, sep, path = origin.partition(":")
    if not sep or kind != "file" or not path:
        return None
    return path


def refusals(gdir):
    lines = []
    for scope, origin, key, value in entries(gdir):
        if scope not in REFUSED_SCOPES or key not in KEYS:
            continue
        shown = quoted(value)
        path = origin_file(origin)
        if path is None:
            where = "from %s" % escape(origin)
            fix = "remove it from that source"
        elif os.path.isabs(path) and escape(path) == path:
            # Quoted: the path is absolute and escapes to itself, so it
            # holds nothing a shell or a terminal would act on, and the
            # quote keeps a space or a `$` in it one literal word. The `in`
            # text is quoted the same way, so a path holding its own
            # "; fix: ..." cannot pass for a fix ahead of the real one.
            where = "in %s" % shlex.quote(path)
            fix = "git config --file %s --unset-all %s" % (
                shlex.quote(path), key)
        else:
            # No command: the printed path is escaped (a backslash doubled,
            # a control character spelled out) or is not absolute, so a
            # command naming it would name another file, which may not
            # exist. The escaped text is still quoted, for the reason above.
            where = "in %s" % shlex.quote(escape(path))
            fix = "remove %s from that file (path shown escaped)" % key
        lines.append("%s %s is set at scope %s %s; fix: %s"
                     % (key, shown, scope, where, fix))
    return lines


def is_oid(b):
    # 40 hex digits for SHA-1, 64 for SHA-256.
    return len(b) in (40, 64) and set(b.decode("ascii", "replace")) <= HEX


def ref_lines(data):
    """(tips, known) from git's pre-push stdin: the local oids pushed, and
    the remote oids the remote already holds. Each line is
    LOCAL_REF SP LOCAL_OID SP REMOTE_REF SP REMOTE_OID; an all-zero local oid
    is a deletion (nothing pushed) and an all-zero remote oid a new ref."""
    tips, known = set(), set()
    lines = data.split(b"\n")
    if lines[-1] == b"":
        lines.pop()
    for line in lines:
        # rsplit: LOCAL_REF is the refspec's source as typed, so it can hold
        # spaces (`HEAD^{/fix bug}`); the last three fields cannot.
        fields = line.rsplit(b" ", 3)
        if len(fields) != 4 or not (is_oid(fields[1]) and is_oid(fields[3])):
            fail("pre-push: a ref line on stdin has an unexpected shape")
        local, remote = fields[1].decode(), fields[3].decode()
        if local.strip("0"):
            tips.add(local)
        if remote.strip("0"):
            known.add(remote)
    return tips, known


def pushed_commits(gdir, tips, known):
    """(oid, author email, committer email) of each commit the push sends.

    Reachable from a pushed tip, minus what any remote-tracking ref or a
    remote oid already reaches. The revisions go on stdin (`^` for an
    exclusion, which every git reads there), so a push of many refs cannot
    outgrow the argument list. --ignore-missing drops a remote oid this
    repository has never fetched; a local oid always exists, since git
    just read it to push it. A tree or blob tip lists no commit."""
    if not tips:
        return []
    revs = "".join("%s\n" % t for t in sorted(tips))
    revs += "".join("^%s\n" % k for k in sorted(known))
    # MUST stay in this order: git reads stdin where `--stdin` stands, and
    # `--not` turns every revision after it into an exclusion, so the tips
    # come before it and the remote-tracking refs after it.
    p = subprocess.run(
        ["git", "rev-list", "--ignore-missing", "--format=%ae%x00%ce",
         "--stdin", "--not", "--remotes"],
        input=revs.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=git_env(gdir))
    if p.returncode != 0:
        git_failed("'git rev-list'", p)
    # Two lines per commit: `commit OID`, then AUTHOR NUL COMMITTER. git
    # takes LF and NUL out of an identity it writes, so any other shape is
    # a commit object built by hand, and the answer is "cannot tell".
    lines = p.stdout.split(b"\n")
    if lines[-1] != b"" or (len(lines) - 1) % 2:
        fail("'git rev-list' printed an unexpected shape")
    out = []
    for i in range(0, len(lines) - 1, 2):
        head, emails = lines[i], lines[i + 1].split(b"\0")
        if not head.startswith(b"commit ") or not is_oid(head[7:]) \
                or len(emails) != 2:
            fail("'git rev-list' printed an unexpected shape")
        out.append((head[7:].decode(), decode(emails[0]), decode(emails[1])))
    return out


def ident_email(gdir, var):
    """The email of `git var VAR` (NAME SP <EMAIL> SP TIME SP TZ)."""
    p = subprocess.run(["git", "var", var], stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, env=git_env(gdir))
    out = decode(p.stdout)
    lt, gt = out.rfind(" <"), out.rfind("> ")
    if p.returncode != 0 or lt < 0 or gt < lt:
        # git explains itself over several lines; the last one says why.
        why = (decode(p.stderr).strip().splitlines() or [""])[-1]
        git_failed("cannot read the effective identity: 'git var %s'" % var,
                   p, why)
    return out[lt + 2:gt]


def commit_refusals(gdir, stdin):
    commits = pushed_commits(gdir, *ref_lines(stdin))
    if not commits:
        return []
    want = [(role, ident_email(gdir, var)) for role, var in IDENTS]
    lines = []
    for oid, *got in commits:
        for (role, effective), email in zip(want, got):
            if email != effective:
                lines.append("commit %s has %s email %s, not the effective "
                             "%s" % (oid, role, quoted(email),
                                     quoted(effective)))
    return lines


def main(argv):
    if len(argv) != 2 or argv[1] not in CALLERS:
        print("usage: commit_identity.py %s" % "|".join(CALLERS),
              file=sys.stderr)
        return 2
    caller = argv[1]
    stdin = b""
    if caller == "pre-push" and sys.stdin is not None:
        stdin = sys.stdin.buffer.read()
    gdir = git_dir()
    lines, pointer = refusals(gdir), None
    if lines:
        pointer = ("a commit identity belongs in the global config; for a "
                   "one-off identity use 'git -c user.email=... -c "
                   "user.name=...' per command instead")
    elif caller == "pre-push":
        lines = commit_refusals(gdir, stdin)
        pointer = ("a pushed commit must carry the effective identity; "
                   "re-make a commit of yours under it (for the tip: 'git "
                   "commit --amend --no-edit --reset-author'); a commit "
                   "made by someone else, once reviewed, goes through "
                   "with 'git push --no-verify'")
    if not lines:
        return 0
    for line in lines:
        print("%s: %s: refusing: %s" % (PREFIX, caller, line),
              file=sys.stderr)
    print("%s: %s: %s" % (PREFIX, caller, pointer), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
