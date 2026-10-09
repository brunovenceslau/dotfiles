# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit checks for .githooks/commit_identity.py that the end-to-end cases in
# tests/commit_identity_test.sh cannot stage with a real git: the error arms
# of entries() (git config failing, an unexpected shape), the refusal text
# for an origin that is not an absolute path, and pre-push's parsing of the
# ref lines, `git rev-list` and `git var`. subprocess.run is replaced
# by a fake that prints canned bytes. Called as
#   python3 -I -B tests/commit_identity_units.py MODULE
# Each check prints one line; any failure exits 1.

import contextlib
import importlib.util
import io
import shlex
import subprocess
import sys

failures = []


def check(cond, what):
    print(("ok: " if cond else "FAIL: ") + what)
    if not cond:
        failures.append(what)


def load(path):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("commit_identity", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


mod = load(sys.argv[1])


def fake(rc, out=b"", err=b""):
    def run(*_args, **_kw):
        return subprocess.CompletedProcess([], rc, stdout=out, stderr=err)
    return run


def fake_git(table, calls):
    """A fake that answers each git subcommand from table, {name: (rc, out)},
    and records (argv, stdin) in calls, for a function that runs several."""
    def run(args, **kw):
        calls.append((args, kw.get("input")))
        rc, out = table[args[1]]
        return subprocess.CompletedProcess(args, rc, stdout=out, stderr=b"")
    return run


def run_with(func, rc, out=b"", err=b"", runner=None):
    """(exit code or None, stderr text, result) of func() under the fake."""
    real = mod.subprocess.run
    mod.subprocess.run = runner or fake(rc, out, err)
    buf = io.StringIO()
    code = result = None
    try:
        with contextlib.redirect_stderr(buf):
            result = func()
    except SystemExit as e:
        code = e.code
    finally:
        mod.subprocess.run = real
    return code, buf.getvalue(), result


def drain(gen):
    return lambda: list(gen())


def entries_case(what, rc, out, err, want):
    code, text, _ = run_with(drain(lambda: mod.entries("/g")), rc, out, err)
    check(code == 2 and text.startswith("commit-identity: ") and want in text,
          "entries(): " + what)


entries_case("git config rc > 1 exits 2", 128, b"", b"boom\n",
             "'git config' failed (exit 128): boom")
# git never prints an entry and exits 1, so only a fake reaches this: the
# pass arm must stay narrow ("no such key" means no output at all), or an
# entry printed with that exit would be dropped instead of checked.
entries_case("git config rc 1 with output exits 2", 1,
             b"local\0file:/g/config\0user.email\na@b\0", b"",
             "'git config' failed (exit 1)")
entries_case("a field count off by one exits 2", 0,
             b"local\0file:/g/config\0user.email\na@b\0local\0",
             b"", "unexpected shape")
entries_case("output without a final NUL exits 2", 0,
             b"local\0file:/g/config\0user.email\na@b", b"",
             "unexpected shape")
entries_case("a key without a value exits 2", 0,
             b"local\0file:/g/config\0user.email\0", b"",
             "key without a value")

code, text, got = run_with(drain(lambda: mod.entries("/g")), 1)
check(code is None and got == [], "entries(): rc 1 and no output is a pass")


def refusal_for(origin):
    out = b"local\0" + origin + b"\0user.email\na@b\0"
    return run_with(lambda: mod.refusals("/g"), 0, out)


code, _, lines = refusal_for(b"file:.git/config")
check(code is None and len(lines) == 1
      and "in '.git/config'; fix: remove user.email from that file" in lines[0]
      and "git config --file" not in lines[0],
      "refusals(): a relative origin path prints no runnable command")

code, _, lines = refusal_for(b"file:/g/config")
check(code is None and lines == ["user.email 'a@b' is set at scope local in "
                                 "'/g/config'; fix: git config --file "
                                 "'/g/config' --unset-all user.email"],
      "refusals(): an absolute origin path prints the command, quoted "
      "(got %r)" % lines)
# The command pasted into a shell names the file itself: one word, intact.
check(code is None and shlex.split(lines[0].split("fix: ", 1)[1])
      == ["git", "config", "--file", "/g/config", "--unset-all",
          "user.email"], "refusals(): the printed command round-trips")

# A quote in a path is spelled \x27, the way a value's is: the quoted word
# cannot close early, so the path's own "; fix:" stays inside it, and the
# changed spelling names another file, so no command is printed.
code, _, lines = refusal_for(b"file:/g/a'; fix: rm x/config")
want = ("user.email 'a@b' is set at scope local in '/g/a\\x27; fix: rm "
        "x/config'; fix: remove user.email from that file (path shown "
        "escaped)")
check(code is None and lines == [want],
      "refusals(): a quote in a path prints as \\x27 (got %r)" % lines)
check(code is None
      and sum(seg.count("; fix: ") for seg in lines[0].split("'")[::2]) == 1
      and shlex.split(lines[0])[8] == "/g/a\\x27; fix: rm x/config;",
      "refusals(): a path holding a quote and '; fix:' is one quoted word "
      "and the line has one fix")

# A space and a `$` stay literal inside single quotes: the command still
# prints, and pasted into a shell it names the file itself.
for path in ("/g/a b/config", "/g/$HOME/config"):
    code, _, lines = refusal_for(b"file:" + path.encode())
    check(code is None and len(lines) == 1
          and shlex.split(lines[0].split("fix: ", 1)[1])
          == ["git", "config", "--file", path, "--unset-all", "user.email"],
          "refusals(): the command for %r round-trips (got %r)"
          % (path, lines))

code, _, lines = refusal_for(b"command line:")
check(code is None and "from command line:" in lines[0],
      "refusals(): a non-file origin names the source")

# pre-push: the ref lines on stdin, rev-list's output and `git var`'s.
Z40, A40, B40 = "0" * 40, "a" * 40, "b" * 40
tips, known = mod.ref_lines(
    ("refs/heads/n %s refs/heads/n %s\n"
     "(delete) %s refs/heads/d %s\n"
     "refs/heads/s %s refs/heads/s %s\n" % (A40, Z40, Z40, B40, "c" * 64,
                                            "d" * 64)).encode())
check(tips == {A40, "c" * 64} and known == {B40, "d" * 64},
      "ref_lines(): a new ref, a deletion and SHA-256 oids")
check(mod.ref_lines(b"") == (set(), set()),
      "ref_lines(): no input pushes nothing")
for what, data in (
        ("three fields", "refs/heads/x %s refs/heads/x\n" % A40),
        ("a short oid", "refs/heads/x abc refs/heads/x %s\n" % Z40),
        ("an upper-case oid", "refs/heads/x %s refs/heads/x %s\n"
         % ("A" * 40, Z40))):
    code, text, _ = run_with(lambda: mod.ref_lines(data.encode()), 0)
    check(code == 2 and "ref line on stdin has an unexpected shape" in text,
          "ref_lines(): %s exits 2" % what)

tips, known = mod.ref_lines(
    ("HEAD^{/fix bug} %s refs/heads/x %s\n" % (A40, Z40)).encode())
check(tips == {A40} and known == set(),
      "ref_lines(): a local ref holding spaces")

code, text, _ = run_with(drain(lambda: mod.entries("/g")), 128)
check(code == 2 and text.rstrip().endswith("'git config' failed (exit 128)"),
      "entries(): a git failure with no stderr names no empty reason")
check(mod.git_env("/g").get("GIT_NO_LAZY_FETCH") == "1",
      "git_env(): a partial clone never fetches lazily for a hook")
check(mod.git_env("/g").get("GIT_NO_REPLACE_OBJECTS") == "1",
      "git_env(): rev-list reads the commits a push sends, not replacements")

def pushed_one(rev_list_out):
    """pushed_commits() of tip A40, which cat-file finds, with rev-list
    printing rev_list_out."""
    return run_with(
        lambda: mod.pushed_commits("/g", {A40}, set()), 0,
        runner=fake_git({"cat-file": (0, ("%s\n" % A40).encode()),
                         "rev-list": (0, rev_list_out.encode())}, []))


def record(oid, *headers, msg="    m\n"):
    """One `git rev-list --header` record: OID, headers, blank, message."""
    return "%s\ntree %s\n%s\n\n%s\0" % (oid, "t" * 40,
                                       "".join(h + "\n" for h in headers),
                                       msg)


AU, CO = "author A <a@x> 1 +0000", "committer C <c@x> 1 +0000"
code, _, got = pushed_one(record(A40, AU, CO) + record(B40, AU, CO))
check(code is None and got == [(A40, "a@x", "c@x"), (B40, "a@x", "c@x")],
      "pushed_commits(): each commit, its author and committer emails")
code, _, got = pushed_one(record(A40, "author <B> x <a@x> 1 +0000", CO,
                                 " author Z <z@x> 1 +0000",
                                 msg="    author Z <z@x>\n"))
check(code is None and got == [(A40, "B", "c@x")],
      "pushed_commits(): the email is read from the first < to the next >, "
      "and a continuation or message line is no header (got %r)" % got)
for what, out in (
        ("no final NUL", record(A40, AU, CO)[:-1]),
        ("a record with no oid", "tree x\n" + AU + "\0")):
    code, text, _ = pushed_one(out)
    check(code == 2 and "'git rev-list' printed an unexpected shape" in text,
          "pushed_commits(): %s exits 2" % what)
# git's readers disagree on a commit with two author headers (%ae reads the
# last, `git show` the first), so anything but one of each is "cannot tell".
for what, out, want in (
        ("two author headers", record(A40, AU, "author G <g@x> 1 +0000", CO),
         "has 2 author headers"),
        ("two committer headers", record(A40, AU, CO, CO),
         "has 2 committer headers"),
        ("no author header", record(A40, CO), "has 0 author headers"),
        ("a NUL inside a message", record(A40, AU, CO, msg="    a\0" + A40
                                          + "\n    " + AU + "\n"),
         "has 0 author headers"),
        ("a header with no <email>", record(A40, "author A a@x 1 +0000", CO),
         "has no <email> in its author header")):
    code, text, _ = pushed_one(out)
    check(code == 2 and ("pre-push: commit %s " % A40) in text
          and want in text,
          "pushed_commits(): %s exits 2 (got %r)" % (what, text))
# A remote oid this repository never fetched leaves the exclusions; a pushed
# tip it lacks cannot be read, which is "cannot tell", never a pass.
calls = []
code, _, got = run_with(
    lambda: mod.pushed_commits("/g", {A40}, {B40}), 0,
    runner=fake_git({"cat-file": (0, ("%s\n%s missing\n" % (A40, B40))
                                  .encode()),
                     "rev-list": (0, record(A40, AU, CO).encode())},
                    calls))
check(code is None and got == [(A40, "a@x", "c@x")]
      and calls[-1][1] == ("%s\n" % A40).encode()
      and "--ignore-missing" not in calls[-1][0],
      "pushed_commits(): a missing remote oid is dropped before rev-list "
      "(calls %r)" % calls)
code, text, _ = run_with(
    lambda: mod.pushed_commits("/g", {A40}, {B40}), 0,
    runner=fake_git({"cat-file": (0, ("%s missing\n%s\n" % (A40, B40))
                                  .encode())}, []))
check(code == 2 and ("pre-push: the pushed object %s is not in this "
                     "repository" % A40) in text,
      "pushed_commits(): a missing pushed tip exits 2 (got %r)" % text)
for what, out in (("a line short", "%s\n" % A40),
                  ("another oid", "%s\n%s\n" % (A40, "e" * 40)),
                  ("another oid missing",
                   "%s\n%s missing\n" % (A40, "e" * 40)),
                  ("an unknown status", "%s\n%s ambiguous\n" % (A40, B40))):
    code, text, _ = run_with(
        lambda: mod.pushed_commits("/g", {A40}, {B40}), 0,
        runner=fake_git({"cat-file": (0, out.encode())}, []))
    check(code == 2 and "'git cat-file' printed an unexpected shape" in text,
          "pushed_commits(): cat-file printing %s exits 2" % what)
code, text, _ = run_with(
    lambda: mod.pushed_commits("/g", {A40}, set()), 0,
    runner=fake_git({"cat-file": (128, b"")}, []))
check(code == 2 and "'git cat-file' failed (exit 128)" in text,
      "pushed_commits(): a failing cat-file exits 2 (got %r)" % text)
code, _, got = run_with(lambda: mod.pushed_commits("/g", set(), {B40}), 128)
check(code is None and got == [],
      "pushed_commits(): no tip runs no git and lists nothing")

code, _, got = run_with(lambda: mod.ident_email("/g", "GIT_AUTHOR_IDENT"), 0,
                        b"A <B> <a@x> 1791515801 -0300\n")
check(code is None and got == "a@x",
      "ident_email(): the email in the last <...> of the ident")
code, text, _ = run_with(lambda: mod.ident_email("/g", "GIT_AUTHOR_IDENT"),
                         128, b"", b"Author identity unknown\n\nfatal: no\n")
check(code == 2 and text.rstrip().endswith("exit 128): fatal: no"),
      "ident_email(): a failing git var exits 2 with its last line")

# commit_refusals(): the cap boundary and the exact compare, with
# pushed_commits() and ident_email() stubbed.
def refusals_for(commits):
    real = mod.pushed_commits, mod.ident_email
    mod.pushed_commits = lambda *_a: commits
    mod.ident_email = lambda *_a: "g@x"
    try:
        return mod.commit_refusals("/g", b"")
    finally:
        mod.pushed_commits, mod.ident_email = real


def foreign(n):
    return [("%040x" % i, "g@x", "c@x") for i in range(n)]


cap = mod.MAX_COMMITS
got = refusals_for(foreign(cap))
check(len(got) == cap and not any("more commit" in g for g in got),
      "commit_refusals(): exactly the cap gives no count line")
got = refusals_for(foreign(cap + 1))
check(len(got) == cap + 1 and got[-1] == "and 1 more commit whose email "
      "differs", "commit_refusals(): one past the cap counts 1 more commit")
got = refusals_for(foreign(cap + 2))
check(got[-1] == "and 2 more commits whose email differs",
      "commit_refusals(): two past the cap counts 2 more commits")
got = refusals_for([(A40, "G@x", "g@x")])
check(got == ["commit %s has author email 'G@x', not the effective 'g@x'"
              % A40], "commit_refusals(): a case-only difference refuses")

# Code points a terminal shows as nothing, though Python counts them
# printable, are spelled out: a value cannot hide text behind them.
got = mod.quoted("a\u3164b\u115f\u2800\u034f\U000e0100")
check(got == "'a\\u3164b\\u115f\\u2800\\u034f\\U000e0100'",
      "quoted(): the Hangul fillers, the braille blank, the CGJ and a "
      "variation selector are escaped (got %r)" % got)

print("commit_identity_units: %d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
