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

A guardrail against accidents, not an enforcement boundary: merge, rebase
and cherry-pick skip pre-commit, pre-push reads config at push time only,
and `--no-verify` or a repository core.hooksPath skips both hooks.

Allowed, by design: `git -c user.email=...` per command (scope `command`,
GIT_CONFIG_COUNT included; the recipe for a scratch commit), the GIT_AUTHOR_* and GIT_COMMITTER_* variables
(not config at all), and the global and system scopes. Nothing else is
checked: no trust root, no signature, no allowed-signers lookup.

The argument names the caller, for the message. `pre-push` also drains stdin:
git writes one line per pushed ref there, and the answer never depends on
them (the rule reads config only), so a ref shape such as a deletion or a
missing remote oid cannot change the result. Draining instead of ignoring
keeps git from meeting a closed pipe on a large push.

Exits 2 when it cannot answer (not a repository, git failing), never 0.

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


def decode(b):
    return b.decode("utf-8", "surrogateescape")


def fail(msg):
    print("%s: %s" % (PREFIX, escape(msg)), file=sys.stderr)
    sys.exit(2)


def git_dir():
    # Honours a GIT_DIR a hook inherits from git: that names the repository
    # being committed in, which is exactly the one to check.
    p = subprocess.run(["git", "rev-parse", "--absolute-git-dir"],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out = decode(p.stdout)
    if p.returncode != 0 or not out.endswith("\n") or "\n" in out[:-1]:
        fail("'git rev-parse --absolute-git-dir' failed (exit %d), not "
             "inside a git repository?: %s"
             % (p.returncode, decode(p.stderr).strip()))
    return out[:-1]


def entries(gdir):
    """Yield (scope, origin, key, value) for each identity key in KEYS.

    GIT_DIR is pinned to the ABSOLUTE git dir: git prints a repository
    origin relative to its own working directory otherwise (`.git/config`
    from a worktree, `config` from inside the git dir or a bare repository),
    and the fix this prints must name a file that exists from anywhere."""
    env = dict(os.environ, GIT_DIR=gdir)
    p = subprocess.run(
        ["git", "config", "--show-scope", "--show-origin", "-z",
         "--get-regexp", KEYS_REGEXP],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    # 1 is "no such key": nothing set anywhere is a pass.
    if p.returncode == 1 and not p.stdout:
        return
    if p.returncode != 0:
        fail("'git config' failed (exit %d): %s"
             % (p.returncode, decode(p.stderr).strip()))
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


def origin_file(origin, gdir):
    """The config file an origin names, or None (`command line:`, `blob:`,
    `standard input:`). A relative path is resolved against the git dir,
    which is what git reports it relative to once GIT_DIR is absolute."""
    kind, sep, path = origin.partition(":")
    if not sep or kind != "file" or not path:
        return None
    return os.path.normpath(os.path.join(gdir, path))


def refusals(gdir):
    lines = []
    for scope, origin, key, value in entries(gdir):
        if scope not in REFUSED_SCOPES or key not in KEYS:
            continue
        shown = "'%s'" % escape(value)
        path = origin_file(origin, gdir)
        if path is None:
            where = "from %s" % escape(origin)
            fix = "remove it from that source"
        elif escape(path) == path:
            # Quoted: the path escapes to itself, so it holds nothing a
            # shell or a terminal would act on, and the quote keeps a space
            # or a `$` in it one literal word.
            where = "in %s" % path
            fix = "git config --file %s --unset-all %s" % (
                shlex.quote(path), key)
        else:
            # No command: the printed path is escaped (a backslash doubled,
            # a control character spelled out), so a command naming it
            # would name another file, which may not exist.
            where = "in %s" % escape(path)
            fix = "remove %s from that file (path shown escaped)" % key
        lines.append("%s %s is set at scope %s %s; fix: %s"
                     % (key, shown, scope, where, fix))
    return lines


def main(argv):
    if len(argv) != 2 or argv[1] not in CALLERS:
        print("usage: commit_identity.py %s" % "|".join(CALLERS),
              file=sys.stderr)
        return 2
    caller = argv[1]
    if caller == "pre-push" and sys.stdin is not None:
        sys.stdin.buffer.read()
    gdir = git_dir()
    lines = refusals(gdir)
    if not lines:
        return 0
    for line in lines:
        print("%s: %s: refusing: %s" % (PREFIX, caller, line),
              file=sys.stderr)
    print("%s: %s: a commit identity belongs in the global config; for a "
          "one-off identity use 'git -c user.email=... -c user.name=...' "
          "per command instead" % (PREFIX, caller), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
