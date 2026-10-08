# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit checks for .githooks/commit_identity.py that the end-to-end cases in
# tests/commit_identity_test.sh cannot stage with a real git: the error arms
# of entries() (git config failing, an unexpected shape) and the refusal
# text for an origin that is not an absolute path. subprocess.run is replaced
# by a fake that prints canned bytes. Called as
#   python3 -I -B tests/commit_identity_units.py MODULE
# Each check prints one line; any failure exits 1.

import contextlib
import importlib.util
import io
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


def run_with(func, rc, out=b"", err=b""):
    """(exit code or None, stderr text, result) of func() under the fake."""
    real = mod.subprocess.run
    mod.subprocess.run = fake(rc, out, err)
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
      and "in .git/config; fix: remove user.email from that file" in lines[0]
      and "git config --file" not in lines[0],
      "refusals(): a relative origin path prints no runnable command")

code, _, lines = refusal_for(b"file:/g/config")
check(code is None and "fix: git config --file /g/config --unset-all "
      "user.email" in lines[0],
      "refusals(): an absolute origin path prints the command")

code, _, lines = refusal_for(b"command line:")
check(code is None and "from command line:" in lines[0],
      "refusals(): a non-file origin names the source")

print("commit_identity_units: %d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
