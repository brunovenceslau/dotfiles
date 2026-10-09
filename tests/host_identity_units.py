# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit checks for lib/host_identity.py that the end-to-end cases in
# tests/host_identity_test.sh cannot stage through install.sh, called as
#   python3 -I -B tests/host_identity_units.py MODULE SCRATCH
# SCRATCH is an empty directory this run may write in. Each check prints one
# line; any failure exits 1. A separate .py file for the reason
# tests/host_identity_conformance.py gives.

import ast
import base64
import contextlib
import errno
import io
import importlib.util
import os
import re
import shlex
import signal
import stat
import struct
import subprocess
import sys
import time

failures = []


def check(cond, what):
    print(("ok: " if cond else "FAIL: ") + what)
    if not cond:
        failures.append(what)


def load(path):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("host_identity", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def wire(*parts):
    return b"".join(struct.pack(">I", len(p)) + p for p in parts)


def key_line(*parts):
    return "%s %s" % (parts[0].decode(), base64.b64encode(wire(*parts)).decode())


def stub(directory, name, body):
    path = os.path.join(directory, name)
    with open(path, "w") as fh:
        fh.write("#!/bin/sh\n" + body)
    os.chmod(path, stat.S_IRWXU)


def cwd_now():
    """os.getcwd(), or why it failed: a check on the working directory
    reports a FAIL line, never a traceback, when that directory is gone."""
    try:
        return os.getcwd()
    except OSError as e:
        return repr(e)


def use_tmpdir(mod, path):
    """Point TMPDIR at PATH for the module's next git_isolate()."""
    mod.git_release()
    os.environ["TMPDIR"] = path
    mod.tempfile.tempdir = None


# The full name of the account every unit runs as (see PinnedPwd).
ACCOUNT_NAME = "Units Account"


class PinnedPwd(object):
    """The pwd module as the module under test sees it in this run: one
    account whose GECOS names it ACCOUNT_NAME. The missing-name line
    suggests the account's full name, and whether the host's own account
    has one is an accident of the host (a macOS runner's does, a Linux
    container's often does not), so a check that read it would pass on one
    platform and fail on the other. The pinned name is never the
    placeholder, so a check that assumes the placeholder fails on every
    host, not only where the account happens to have a name."""

    class _Entry(object):
        pw_name, pw_gecos = "units", ACCOUNT_NAME + ",Room 1"

    def getpwuid(self, uid):
        return self._Entry()


def git_units(mod, scratch):
    os.environ.update({
        "GIT_DIR": "/some/repo/.git",
        "GIT_WORK_TREE": "/some/repo",
        "GIT_CONFIG_PARAMETERS": "'user.email'='evil@x'",
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "user.email",
        "GIT_CONFIG_VALUE_0": "evil@x",
        "GIT_CONFIG_GLOBAL": "/custom/global",
        "GIT_CONFIG_SYSTEM": "/custom/system",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CEILING_DIRECTORIES": "/inherited",
    })
    env = mod.git_env("/ceiling")
    check("GIT_DIR" not in env, "git_env drops GIT_DIR rather than pointing it anywhere")
    check(env.get("GIT_CEILING_DIRECTORIES") == "/ceiling", "git_env sets the one ceiling it is given")
    check(not any(k in env for k in ("GIT_WORK_TREE", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
                                     "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0")),
          "git_env drops the repository-local and -c variables")
    check(env.get("GIT_CONFIG_GLOBAL") == "/custom/global" and env.get("GIT_CONFIG_SYSTEM") == "/custom/system"
          and env.get("GIT_CONFIG_NOSYSTEM") == "1", "git_env keeps the global and system file selectors")

    # A stub git: it answers the isolation check the way git does outside a
    # repository, and records what any other call saw.
    real_path = os.environ["PATH"]
    bindir = os.path.join(scratch, "bin")
    os.mkdir(bindir)
    record = os.path.join(scratch, "git-env")
    cwd_record = os.path.join(scratch, "git-cwd")
    # STUB_REVPARSE picks the answer to `git rev-parse`: git's own outside a
    # repository by default, or a failure that is not that answer.
    stub(bindir, "git", 'if [ "$1" = rev-parse ]; then\n'
         '  case "${STUB_REVPARSE:-}" in\n'
         '    dubious) echo "fatal: detected dubious ownership in repository at \'/x\'" >&2; exit 128 ;;\n'
         '    silent) exit 127 ;;\n'
         '    embedded) echo "fatal: refusing: not a git repository is not what happened" >&2; exit 128 ;;\n'
         '  esac\n'
         '  echo "fatal: not a git repository (or any of the parent directories): .git" >&2; exit 128\n'
         'fi\nenv > "%s"\npwd -P > "%s"\nls -A > "%s.ls"\nexit 1\n' % (record, cwd_record, cwd_record))
    os.environ["PATH"] = bindir + os.pathsep + real_path
    tmpdir = os.path.join(scratch, "tmp")
    os.mkdir(tmpdir, 0o700)
    use_tmpdir(mod, tmpdir)
    here = os.getcwd()
    mod.git(["config", "--get", "user.email"])
    with open(record) as fh:
        seen = dict(line.split("=", 1) for line in fh.read().splitlines() if "=" in line)
    check("GIT_DIR" not in seen and "GIT_WORK_TREE" not in seen and "GIT_CONFIG_PARAMETERS" not in seen
          and seen.get("GIT_CONFIG_GLOBAL") == "/custom/global" and seen.get("GIT_CONFIG_NOSYSTEM") == "1",
          "the git child process sees exactly the scrubbed environment")
    with open(cwd_record) as fh:
        ran_in = fh.read().strip()
    with open(cwd_record + ".ls") as fh:
        listing = fh.read()
    check(os.path.dirname(ran_in) == os.path.realpath(tmpdir) and listing == "",
          "git runs from a fresh, empty directory under $TMPDIR")
    check(seen.get("GIT_CEILING_DIRECTORIES") == os.path.realpath(tmpdir),
          "the ceiling is that directory's parent, replacing an inherited one")
    mod.git(["config", "--get", "user.name"])
    with open(cwd_record) as fh:
        check(fh.read().strip() == ran_in and os.listdir(tmpdir) == [os.path.basename(ran_in)],
              "every git call of one process shares that one directory")
    made = mod._git_place.made
    check(os.path.realpath(made) == ran_in, "the directory made is the one git ran from")
    mod.git_release()
    check(not os.path.exists(made) and os.listdir(tmpdir) == [] and mod._git_place is None,
          "git_release() removes it at once, while this test still holds its path")
    check(cwd_now() == here, "deciding where git runs leaves this process's working directory as it was")
    os.chdir(here)  # so a failure above does not take the checks below with it
    try:
        mod._getcwd_in(os.path.join(scratch, "missing"))
        check(False, "_getcwd_in() of a missing directory raises")
    except OSError:
        check(cwd_now() == here, "a failed _getcwd_in() leaves the working directory as it was")
    except Exception as e:
        check(False, "_getcwd_in() of a missing directory raises OSError, not %r" % e)
    os.chdir(here)

    # A way back found but not taken: from a working directory without any
    # permission, "." cannot be opened, Linux's getcwd() still names it, and
    # stepping back into it fails. (macOS's getcwd() may not name it: the
    # refusal there is the one for no way back, tested below.)
    if hasattr(os, "O_PATH"):
        sealed = os.path.join(scratch, "sealed")
        os.mkdir(sealed, 0o700)
        os.chdir(sealed)
        os.chmod(sealed, 0)
        try:
            use_tmpdir(mod, tmpdir)
            try:
                reason = mod.git_isolate()
            except Exception as e:
                reason = repr(e)
            check(reason is not None and reason.startswith("cannot return to the current directory ("),
                  "a way back that cannot be taken is a refusal of its own (%s)" % reason)
            mod.git_release()
            check(os.listdir(tmpdir) == [], "the empty directory is removed after a failed return")
        finally:
            os.chmod(sealed, 0o700)
            os.chdir(here)

    # The way back: a descriptor that needs no read permission where the
    # platform has one, else the path; no way back at all is a refusal.
    fds = "/proc/self/fd"
    if os.path.isdir(fds):
        before = sorted(os.listdir(fds))
        mod._getcwd_in(tmpdir)
        check(sorted(os.listdir(fds)) == before, "_getcwd_in() closes the descriptor it returns through")
    else:
        print("SKIP: no /proc/self/fd here; the descriptor count is not checked")
    xonly = os.path.join(scratch, "xonly")
    os.mkdir(xonly, 0o700)
    os.chdir(xonly)
    # The checks below compare with getcwd(), so xonly takes its spelling:
    # SCRATCH may sit behind a symlink (macOS's TMPDIR is /var/folders/...,
    # which getcwd() names /private/var/folders/...).
    xonly = os.getcwd()
    os.chmod(xonly, 0o311)
    try:
        if hasattr(os, "O_PATH"):
            try:
                os.close(os.open(".", mod._BACK_FLAGS))
                check(True, "an execute-only working directory opens as a place to return to (O_PATH)")
            except OSError as e:
                check(False, "an execute-only working directory opens as a place to return to (O_PATH): %s" % e)
            use_tmpdir(mod, tmpdir)
            check(mod.git_isolate() is None and cwd_now() == xonly,
                  "from an execute-only working directory git still runs, and the directory is restored")
            mod.git_release()
        real_open = mod.os.open
        real_getcwd = mod.os.getcwd

        def no_dot(path, *a, **k):
            if path == ".":
                raise OSError(errno.EACCES, "Permission denied", ".")
            return real_open(path, *a, **k)

        mod.os.open = no_dot
        try:
            try:
                seen = mod._getcwd_in(tmpdir)
            except Exception as e:
                seen = repr(e)
            check(seen == os.path.realpath(tmpdir) and cwd_now() == xonly,
                  "without a descriptor, the way back is the path getcwd() names")

            def no_getcwd():
                raise OSError(errno.EACCES, "Permission denied")

            mod.os.getcwd = no_getcwd
            use_tmpdir(mod, tmpdir)
            reason = mod.git_isolate()
            mod.os.getcwd = real_getcwd
            check(reason is not None and reason.startswith("cannot open the current directory to return to it (")
                  and cwd_now() == xonly,
                  "with no way back at all the step refuses, without stepping anywhere")
            mod.git_release()
        finally:
            mod.os.open = real_open
            mod.os.getcwd = real_getcwd
    finally:
        os.chmod(xonly, 0o700)
        os.chdir(here)

    def refused(what, needle):
        if os.path.exists(record):
            os.unlink(record)
        try:
            rc, _, err = mod.git(["config", "--get", "user.email"])
            again = mod.git(["config", "--get", "user.email"])
        except Exception as e:
            rc, err, again = None, repr(e), None
        check(rc == 127 and needle in err and not os.path.exists(record),
              "%s: git refuses (%s), the config is not read" % (what, err))
        check(again == (127, "", err), "%s: the refusal is remembered" % what)

    colon = os.path.join(scratch, "a:b")
    os.mkdir(colon, 0o700)
    use_tmpdir(mod, colon)
    refused("a ceiling holding ':' (git's list separator)", "cannot express")
    mod.git_release()
    check(os.listdir(colon) == [], "the refused directory is removed all the same")

    open_dir = os.path.join(scratch, "open")
    os.mkdir(open_dir)
    os.chmod(open_dir, 0o777)
    use_tmpdir(mod, open_dir)
    refused("a TMPDIR writable by every user, not sticky", "writable by every user and not sticky")
    os.chmod(open_dir, 0o777 | stat.S_ISVTX)
    use_tmpdir(mod, open_dir)
    check(mod.git_isolate() is None, "the same TMPDIR with the sticky bit (as /tmp) is accepted")
    mod.git_release()
    os.chmod(open_dir, 0o700)

    use_tmpdir(mod, tmpdir)
    real_mkdtemp = mod.tempfile.mkdtemp

    def no_tempdir(*a, **k):
        raise OSError(errno.ENOSPC, "No space left on device")

    mod.tempfile.mkdtemp = no_tempdir
    try:
        refused("no empty directory can be made", "No space left on device")
    finally:
        mod.tempfile.mkdtemp = real_mkdtemp

    for answer, needle in (("dubious", "git cannot start (fatal: detected dubious ownership"),
                           ("silent", "git cannot start (exit 127)"),
                           ("embedded", "git cannot start (fatal: refusing: not a git repository")):
        use_tmpdir(mod, tmpdir)
        os.environ["STUB_REVPARSE"] = answer
        refused("git rev-parse failing with %s" % answer, needle)
        check(answer != "dubious" or "detected dubious ownership" in mod.git_isolate(),
              "the refusal quotes git's own error")
        del os.environ["STUB_REVPARSE"]
    mod.git_release()

    real_stat = mod.os.stat

    def no_stat(path, *a, **k):
        if path == os.path.realpath(tmpdir):
            raise OSError(errno.EACCES, "Permission denied")
        return real_stat(path, *a, **k)

    use_tmpdir(mod, tmpdir)
    mod.os.stat = no_stat
    try:
        refused("the ceiling cannot be stat()ed", "cannot stat %s: Permission denied" % os.path.realpath(tmpdir))
    finally:
        mod.os.stat = real_stat

    # The decision is one state: git runs only once it is proven, and an
    # interrupted decision stays a refusal.
    mod.git_release()
    mod._git_place = mod.GitPlace()
    try:
        rc, _, err = mod.git(["config", "--get", "user.email"])
    except Exception as e:
        rc, err = None, repr(e)
    check(rc == 127 and err == mod.UNDECIDED and not os.path.exists(record),
          "git() runs nothing for a place that has no proven directory (%s)" % err)
    mod.git_release()
    real_isolate = mod._isolate

    def interrupted(place):
        place.made = mod.tempfile.mkdtemp(prefix="host_identity.git.")
        raise KeyboardInterrupt

    use_tmpdir(mod, tmpdir)
    mod._isolate = interrupted
    try:
        try:
            mod.git_isolate()
            check(False, "an interrupt in the decision propagates")
        except KeyboardInterrupt:
            pass
    finally:
        mod._isolate = real_isolate
    try:
        rc, _, err = mod.git(["config", "--get", "user.email"])
    except Exception as e:
        rc, err = None, repr(e)
    check(rc == 127 and "interrupted" in err, "an interrupted decision is a refusal, not a success (%s)" % err)
    mod.git_release()
    check(os.listdir(tmpdir) == [], "the directory an interrupted decision made is removed")

    # entry(): ^C ends the process by SIGINT, with git's directory removed.
    # In a child, since that is the point.
    use_tmpdir(mod, tmpdir)
    child = (
        "import importlib.util, sys\n"
        "spec = importlib.util.spec_from_file_location('m', sys.argv[1])\n"
        "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
        "def run(host, mode, name, report_stale, verbose=False):\n"
        "    m.git(['config', '--get', 'user.email'])\n"
        "    raise KeyboardInterrupt\n"
        "m.run = run\n"
        "sys.exit(m.entry(['--config-local', sys.argv[2], '--mode', 'check']))\n"
    )
    env = dict(os.environ, HOME=scratch, TMPDIR=tmpdir)
    p = subprocess.run([sys.executable, "-I", "-B", "-c", child, mod.__file__, os.path.join(scratch, "c.local")],
                       env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    check(p.returncode == -signal.SIGINT and b"Traceback" not in p.stderr and os.listdir(tmpdir) == [],
          "an interrupt ends the process by SIGINT, without a traceback, git's directory removed (rc %d)"
          % p.returncode)

    for name in ("GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM"):
        use_tmpdir(mod, tmpdir)
        old = os.environ[name]
        os.environ[name] = ".gitconfig"
        refused("a relative %s" % name, "%s=.gitconfig is not an absolute path" % name)
        os.environ[name] = old
    mod.git_release()
    check(os.listdir(tmpdir) == [], "no refusal leaves a directory behind")

    # The proof itself, with the real git: were the ceiling lost, git would
    # find the repository holding $TMPDIR, and the step must refuse.
    for k in [k for k in os.environ if k.startswith("GIT_")]:
        del os.environ[k]
    os.environ["PATH"] = real_path
    os.environ["GIT_CONFIG_SYSTEM"] = os.devnull
    os.environ["GIT_CONFIG_GLOBAL"] = os.devnull
    hostile = os.path.join(scratch, "hostile")
    subprocess.run(["git", "init", "-q", hostile], check=True, stdin=subprocess.DEVNULL)
    inside = os.path.join(hostile, "tmp")
    os.mkdir(inside, 0o700)
    use_tmpdir(mod, inside)
    check(mod.git_isolate() is None, "a TMPDIR inside a repository passes: the ceiling holds")
    os.environ.update({"GIT_TRACE": "1", "GIT_TRACE2": "1", "GIT_TRACE_SETUP": "1"})
    env = mod.git_env("/c")
    for trace in ("GIT_TRACE", "GIT_TRACE2", "GIT_TRACE_SETUP"):
        del os.environ[trace]
    check(sorted(k for k in env if k.startswith("GIT_TRACE")) == ["GIT_TRACE2", "GIT_TRACE2_EVENT", "GIT_TRACE2_PERF"]
          and all(env[k] == "0" for k in ("GIT_TRACE2", "GIT_TRACE2_EVENT", "GIT_TRACE2_PERF")),
          "git_env drops every inherited GIT_TRACE* variable and turns the trace2 targets off")
    for trace in ("GIT_TRACE", "GIT_TRACE2"):
        os.environ[trace] = "1"
        use_tmpdir(mod, inside)
        reason = mod.git_isolate()
        del os.environ[trace]
        check(reason is None, "%s=1 does not turn the guard into a refusal (%s)" % (trace, reason))
    # A trace2 target set in a config file, not in the environment: only
    # GIT_TRACE2*=0 in the environment overrides it.
    traced = os.path.join(scratch, "traced.gitconfig")
    for target in ("normalTarget", "eventTarget", "perfTarget"):
        for value in ("1", "2"):
            with open(traced, "w") as fh:
                fh.write("[trace2]\n\t%s = %s\n" % (target, value))
            os.environ["GIT_CONFIG_GLOBAL"] = traced
            use_tmpdir(mod, inside)
            reason = mod.git_isolate()
            os.environ["GIT_CONFIG_GLOBAL"] = os.devnull
            check(reason is None, "trace2.%s=%s in the global config does not turn the guard into a refusal (%s)"
                  % (target, value, reason))
    link = os.path.join(scratch, "tmp-link")
    os.symlink(inside, link)
    use_tmpdir(mod, link)
    check(mod.git_isolate() is None and mod._git_place.ceiling == os.path.realpath(inside),
          "a TMPDIR that is a symlink into a repository passes, its ceiling spelled as getcwd() spells it")
    real_env = mod.git_env
    mod.git_env = lambda ceiling: {k: v for k, v in real_env(ceiling).items() if k != "GIT_CEILING_DIRECTORIES"}
    try:
        use_tmpdir(mod, inside)
        refused("without the ceiling, git finds the repository around TMPDIR", "git finds a repository")
    finally:
        mod.git_env = real_env
    mod.git_release()
    check(os.listdir(inside) == [], "nothing is left inside the repository")


def main_twice_units(mod, scratch):
    """main() run more than once in one process: what one run decides about
    the automatic step's line never reaches the next. A copy of the tracked
    config's bytes is included first, as the link engine does, so its
    commit.gpgsign = true is read; its relative include then reaches no
    repo-side config.local."""
    module_dir = os.path.dirname(os.path.abspath(mod.__file__))
    tracked = os.path.join(scratch, "tracked", "config")
    os.makedirs(tracked)
    with open(os.path.join(module_dir, os.pardir, "config", "git", "config")) as fh:
        body = fh.read()
    with open(os.path.join(tracked, "config"), "w") as fh:
        fh.write(body)
    home = os.path.join(scratch, "twice")
    gitdir = os.path.join(home, ".config", "git")
    os.makedirs(gitdir)
    with open(os.path.join(gitdir, "config"), "w") as fh:
        fh.write("[include]\n\tpath = %s\n[include]\n\tpath = config.local\n" % os.path.join(tracked, "config"))
    local = os.path.join(gitdir, "config.local")
    # No agent of the caller's: doctor asks one for its keys.
    for name in ("GIT_CONFIG_GLOBAL", "SSH_CONNECTION", "CANGA_HOST_ALLOWED_SIGNERS", "SSH_AUTH_SOCK", "SSH_AGENT_PID"):
        os.environ.pop(name, None)
    os.environ.update({"HOME": home, "XDG_CONFIG_HOME": os.path.join(home, ".config"),
                       "GIT_CONFIG_SYSTEM": os.devnull})

    def said(mode):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            rc = mod.main(["--config-local", local, "--installer", "INST", "--mode", mode])
        return rc, out.getvalue()

    # No key and no allowed-signers file: the tracked true fails closed.
    rc, text = said("auto")
    check(rc == 1 and "; every commit fails until this host has a signing key" in text,
          "a first auto run on a host that fails closed names the consequence (%r)" % text)
    # The same process, now with a key: the refusal no longer fails closed.
    with open(local, "w") as fh:
        fh.write("[user]\n\tsigningkey = key::ssh-ed25519 AAAA\n")
    rc, text = said("auto")
    check(rc == 1 and "every commit fails" not in text and "(details: INST identity)" in text,
          "a second auto run on a keyed host carries nothing over from the first (%r)" % text)
    os.remove(local)
    for mode in ("check", "doctor"):
        rc, text = said("auto")
        check("; every commit fails until this host has a signing key" in text,
              "the auto run before --mode %s fails closed (%r)" % (mode, text))
        rc, text = said(mode)
        check("every commit fails until" not in text,
              "--mode %s after a fail-closed auto run does not repeat its suffix (%r)" % (mode, text))


# A hostile value: an OSC sequence that retitles the terminal, then BEL.
OSC = "\x1b]0;PWNED\x07"
OSC_SHOWN = "\\x1b]0;PWNED\\x07"
K1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE7ZriufNPIzaGKLCOFNHpr6/MYnrT97GT7G1THBmdJR"


def printable(text):
    """Nothing in TEXT a terminal acts on: every character printable but the
    newlines between lines."""
    return all(c == "\n" or c.isprintable() for c in text)


class HostileHost(object):
    """A HOME shaped like the link engine's, a fake ssh-add holding K1, and
    main() run in this process with its output captured. Each value the
    module reads from the host can be set to one a terminal would act on."""

    def __init__(self, mod, scratch, name):
        self.mod = mod
        module_dir = os.path.dirname(os.path.abspath(mod.__file__))
        self.home = os.path.join(scratch, name)
        self.gitdir = os.path.join(self.home, ".config", "git")
        os.makedirs(self.gitdir)
        tracked = os.path.join(self.home, "tracked")
        with open(os.path.join(module_dir, os.pardir, "config", "git", "config")) as fh:
            body = fh.read()
        with open(tracked, "w") as fh:
            fh.write(body)
        with open(os.path.join(self.gitdir, "config"), "w") as fh:
            # Quoted: a `;` in a hostile HOME would start a comment.
            fh.write('[include]\n\tpath = "%s"\n[include]\n\tpath = config.local\n' % tracked)
        self.local = os.path.join(self.gitdir, "config.local")
        self.signers = os.path.join(self.gitdir, "allowed_signers")
        with open(self.signers, "w") as fh:
            fh.write("me@example.com %s\n" % K1)
        bindir = os.path.join(self.home, "bin")
        os.mkdir(bindir)
        stub(bindir, "ssh-add", 'printf "%%s\\n" "%s agent-comment"\n' % K1)
        for k in [k for k in os.environ if k.startswith("GIT_")]:
            del os.environ[k]
        for k in ("SSH_CONNECTION", "CANGA_HOST_ALLOWED_SIGNERS", "SSH_AUTH_SOCK", "SSH_AGENT_PID"):
            os.environ.pop(k, None)
        os.environ.update({"HOME": self.home, "XDG_CONFIG_HOME": os.path.join(self.home, ".config"),
                           "GIT_CONFIG_SYSTEM": os.devnull,
                           "PATH": bindir + os.pathsep + os.environ["PATH"]})

    def set(self, **values):
        """config.local holding VALUES, a key's dots spelled as `__`
        (`gpg__ssh__revocationFile`: the middle part is a subsection)."""
        with open(self.local, "w") as fh:
            for key, value in values.items():
                parts = key.split("__")
                section, name = " ".join(parts[:1] + ['"%s"' % p for p in parts[1:-1]]), parts[-1]
                escaped = value.replace("\\", "\\\\").replace('"', '\\"')
                fh.write('[%s]\n\t%s = "%s"\n' % (section, name, escaped))

    def said(self, mode, *extra, **kw):
        out = io.StringIO()
        args = ["--config-local", kw.get("local", self.local), "--installer", kw.get("installer", "INST"),
                "--mode", mode] + list(extra)
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            rc = self.mod.main(args)
        return rc, out.getvalue()


def escaping_units(mod, scratch):
    """Each value a message interpolates is escaped where it is put in, and
    only it: the literal text around it prints as written."""
    check(mod.escape("a\\b\x1b\r\u202e\u200b\udcff\U000e0001 \u00e9") == "a\\\\b\\x1b\\x0d\\u202e\\u200b\\xff\\U000e0001 \u00e9",
          "escape() doubles a backslash and spells out controls, bidi and zero-width characters, and non-UTF-8 bytes")
    check(mod.quoted("it's") == "'it\\x27s'", "quoted() spells a quote inside the value as \\x27")
    check(mod._shown("Jane O Doe") == "Jane O Doe" and mod._shown("a\\b") == "'a\\\\b'"
          and mod._shown(OSError(2, "x" + OSC)) == "'[Errno 2] x%s'" % OSC_SHOWN,
          "_shown() keeps a plain value bare and quotes one escape() changes, an exception's text included")
    check([mod._shown(v) for v in ("", " lead", "trail ", "\tx")] == ["''", "' lead'", "'trail '", "'\\x09x'"],
          "_shown() quotes an empty value and one that starts or ends with a space")
    check([mod._shown(v) for v in ("a b", "a  b", "me@x.org" + " " * 40 + "fix: run this")]
          == ["a b", "'a  b'", "'me@x.org%sfix: run this'" % (" " * 40)],
          "_shown() keeps a single inner space bare and quotes a run of spaces")
    # A zero-width mark between the spaces does not hide the run: marks
    # (Mn, Me) are left out of the space tests, so a space-mark run, or a
    # space followed only by marks at an edge, is quoted. A mark on a letter
    # (a decomposed e-acute) keeps a name bare.
    forged = "me@x.org" + " \u2d7f" * 40 + "fix: run this"
    check([mod._shown(v) for v in (forged, "x \u0301", "\u20dd x", "\u0301", "Jose\u0301 Doe")]
          == ["'%s'" % forged, "'x \u0301'", "'\u20dd x'", "'\u0301'", "Jose\u0301 Doe"],
          "_shown() quotes a run of spaces, an edge space or a value that combining marks pad, and keeps an accented name bare")
    # What quoting does not promise: a long value of single spaces stays
    # bare, and a terminal may wrap it like any long text.
    long_words = "x " * 36 + "identity: signing is set up"
    check(mod._shown(long_words) == long_words, "_shown() keeps a long value of single spaces bare")
    # The code points a terminal shows as nothing, though Python counts them
    # printable: escaped, so a value cannot hide text behind them.
    blanks = "\u3164\u115f\u2800\u034f\ufe0f\U000e0100\U0001d159"
    check(mod.escape("a" + blanks + "b") == "a\\u3164\\u115f\\u2800\\u034f\\ufe0f\\U000e0100\\U0001d159b"
          and mod._shown("Jane\u3164Doe") == "'Jane\\u3164Doe'",
          "escape() spells out the Hangul fillers, the braille blank, the CGJ, the variation selectors and the null notehead")
    # One rule for both printers: .githooks/commit_identity.py keeps its own
    # escape() (it runs alone), held here to this one over every code point.
    hook = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, ".githooks", "commit_identity.py")
    spec = importlib.util.spec_from_file_location("commit_identity", hook)
    other = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(other)
    differ = [hex(o) for o in range(0x110000) if mod.escape(chr(o)) != other.escape(chr(o))]
    check(not differ, "escape() in .githooks/commit_identity.py spells every code point the same (differ: %r)" % differ[:10])
    check(mod._bare("identity: cannot read /a - writing nothing/b: x - writing nothing")
          == "cannot read /a - writing nothing/b: x", "_bare() strips only the trailing ' - writing nothing'")
    h = HostileHost(mod, scratch, "hostile")

    # identity: a config value the step leaves as it is.
    h.set(user__email="me@example.com", user__signingkey="key::ssh-ed25519 AAAA" + OSC)
    rc, text = h.said("identity")
    check(rc == 1 and printable(text)
          and "identity: user.signingkey is already set to a different value - leaving it: 'key::ssh-ed25519 AAAA%s'"
          % OSC_SHOWN in text,
          "identity quotes a kept value holding a control character, and only it (%r)" % text)

    # identity: a user.email no agent key is listed for.
    h.set(user__email="me‮@example.com")
    rc, text = h.said("identity")
    check(rc == 1 and printable(text)
          and "identity: no ssh-agent key is listed for user.email 'me\\u202e@example.com' - writing nothing" in text,
          "identity quotes a user.email holding a bidi character (%r)" % text)

    # rotate: a user.signingkey path that names nothing.
    h.set(user__email="me@example.com", user__signingkey="~/x" + OSC)
    rc, text = h.said("rotate")
    check(rc == 1 and printable(text)
          and "identity: --rotate: user.signingkey ('~/x%s') names no readable public key - refusing" % OSC_SHOWN
          in text, "rotate quotes the user.signingkey it cannot read (%r)" % text)

    # doctor: the literal head stays bare, the value is quoted.
    h.set(user__email="me@example.com", user__name="Jane" + OSC + "Doe")
    rc, text = h.said("doctor", "--verbose")
    check(printable(text) and "install: doctor: values: user.name = 'Jane%sDoe' (file:%s)" % (OSC_SHOWN, h.local)
          in text, "doctor quotes a value, not its whole line (%r)" % text)

    # A config.local path holding a control character: the refusal before
    # any git read, in identity and in doctor.
    odd = os.path.join(scratch, "dir" + OSC)
    os.makedirs(os.path.join(odd, "config.local"))
    odd_shown = "'%s'" % os.path.join(scratch, "dir" + OSC_SHOWN)
    for mode, want in (("identity", "install: identity: %s/config.local' is not a regular file - writing nothing"),
                       ("doctor", "install: doctor: git: %s/config.local' is not a regular file - git opens it")):
        rc, text = h.said(mode, local=os.path.join(odd, "config.local"))
        check(rc == 1 and printable(text) and want % odd_shown[:-1] in text,
              "%s quotes a config.local path holding a control character (%r)" % (mode, text))

    # Environment values: a GIT_CONFIG_GLOBAL and a CANGA_HOST_ALLOWED_SIGNERS.
    h.set(user__email="me@example.com")
    os.environ["GIT_CONFIG_GLOBAL"] = os.path.join(scratch, "global" + OSC)
    rc, text = h.said("identity")
    del os.environ["GIT_CONFIG_GLOBAL"]
    check(rc == 1 and printable(text) and "identity: GIT_CONFIG_GLOBAL='%s' is not " % os.path.join(scratch, "global" + OSC_SHOWN)
          in text, "identity quotes a GIT_CONFIG_GLOBAL holding a control character (%r)" % text)
    os.environ["CANGA_HOST_ALLOWED_SIGNERS"] = os.path.join(scratch, "signers" + OSC)
    for mode in ("identity", "doctor"):
        rc, text = h.said(mode)
        check(rc == 1 and printable(text) and "the allowed-signers file '%s' (from CANGA_HOST_ALLOWED_SIGNERS)"
              % os.path.join(scratch, "signers" + OSC_SHOWN) in text,
              "%s quotes a CANGA_HOST_ALLOWED_SIGNERS holding a control character (%r)" % (mode, text))
    del os.environ["CANGA_HOST_ALLOWED_SIGNERS"]

    # auto: main() prints ONE line, its headline plus a suffix that names
    # the installer; the suffix's value is escaped like any other.
    inst = "/opt/inst" + OSC + "/install.sh"
    inst_shown = "'/opt/inst%s/install.sh'" % OSC_SHOWN
    h.set(user__signingkey="key::ssh-ed25519 AAAA", user__name="Jane")
    rc, text = h.said("auto", installer=inst)
    check(rc == 1 and printable(text) and text.count("\n") == 1
          and text.endswith(" (details: %s identity)\n" % inst_shown),
          "auto's one line escapes the installer in its details suffix (%r)" % text)
    h.set(user__email="other@example.com")
    rc, text = h.said("auto", installer=inst)
    check(rc == 1 and printable(text) and text.count("\n") == 1
          and "; every commit fails until this host has a signing key - run %s identity on this host" % inst_shown
          in text, "auto's one line escapes the installer in its fail-closed suffix (%r)" % text)

    # ~/.gitconfig's key names, joined by ", ": a name holding a comma or a
    # quote (a subsection can) is quoted, so the list still reads as its
    # names.
    gc_home = os.path.join(scratch, "gitconfig-names")
    os.mkdir(gc_home)
    with open(os.path.join(gc_home, ".gitconfig"), "w") as fh:
        fh.write('[user "a, b"]\n\tx = 1\n[user "it\'s"]\n\ty = 1\n[user]\n\temail = e@x\n')
    level, finding = mod.gitconfig_finding(mod.Host(gc_home, os.path.join(gc_home, "c"), "INSTALLER"))
    check(level == "problem" and finding.startswith("~/.gitconfig sets 'user.a, b.x', user.email, 'user.it\\x27s.y', and"),
          "a ~/.gitconfig key name holding a comma or a quote is quoted in the list (%r)" % finding)

    # The sweep: every mode on a host whose every value holds one, nothing
    # printed raw.
    revocation = os.path.join(scratch, "revoked" + OSC)
    with open(revocation, "w") as fh:
        fh.write("not a key\n")
    hostile = dict(user__name="Jane" + OSC, user__email="me" + OSC + "@example.com",
                   user__signingkey="~/.ssh/" + OSC, gpg__format="ssh" + OSC,
                   gpg__ssh__revocationFile=revocation)
    sweeps = [hostile, dict(hostile, gpg__format="ssh"), dict(hostile, gpg__format="ssh", user__email="me@example.com"),
              dict(user__email="me@example.com", user__signingkey="key::" + K1, commit__gpgsign="false" + OSC),
              dict(user__email="me@example.com", user__signingkey="key::" + K1, user__name="Jane",
                   gpg__ssh__revocationFile=revocation),
              dict(user__email="me@example.com", user__signingkey="key::" + K1, user__name="Jane",
                   gpg__ssh__allowedSignersFile=os.path.join(scratch, "nowhere" + OSC))]
    modes = (("identity", ()), ("auto", ("--report-stale",)), ("check", ()), ("rotate", ()), ("doctor", ("--verbose",)))
    for n, values in enumerate(sweeps):
        h.set(**values)
        for mode, extra in modes:
            rc, text = h.said(mode, *extra)
            check(printable(text) and "Traceback" not in text,
                  "sweep %d, %s: nothing printed raw (%r)" % (n, mode, text))

    # The paths themselves: a HOME and a TMPDIR holding one, so every line
    # that names config.local, the allowed-signers file, an origin or git's
    # directory names a hostile path, end to end.
    h = HostileHost(mod, scratch, "home" + OSC)
    tmpdir = os.path.join(scratch, "tmp" + OSC)
    os.mkdir(tmpdir, 0o700)
    use_tmpdir(mod, tmpdir)
    rows = [dict(), dict(user__signingkey="key::ssh-ed25519 AAAA"), dict(commit__gpgsign="false"),
            dict(user__email="me@example.com", user__signingkey="key::" + K1, user__name="Jane",
                 gpg__ssh__revocationFile=os.path.join(h.home, "revoked")),
            dict(user__email="me@example.com", user__signingkey="~/.ssh/nothing", user__name="Jane")]
    for n, values in enumerate(rows):
        for mode, extra in modes:
            if os.path.exists(h.local):
                os.remove(h.local)
            h.set(**values)
            rc, text = h.said(mode, *extra)
            check(printable(text) and "Traceback" not in text and h.home not in text,
                  "hostile HOME and TMPDIR, row %d, %s: nothing printed raw (%r)" % (n, mode, text))
    rc, text = h.said("doctor", "--verbose")
    check("('file:%s/.config/git/config.local')" % os.path.join(scratch, "home" + OSC_SHOWN) in text,
          "a hostile HOME prints quoted and escaped in an origin (%r)" % text)
    check(os.listdir(tmpdir) == [], "a hostile TMPDIR is left empty")
    mod.tempfile.tempdir = None


def command_word_units(mod, scratch):
    """A fix line's command names config.local and the installer as one
    shell word each, so it runs as printed from a HOME holding a space."""
    h = HostileHost(mod, scratch, "with space")
    inst = os.path.join(h.home, "dot files", "install.sh")

    def command(text, head):
        """The words of the command after HEAD in TEXT's line holding it."""
        for line in text.splitlines():
            if head in line:
                return shlex.split(line.split(head, 1)[1])
        return None

    # An opted-out host: doctor's fixes name config.local.
    h.set(commit__gpgsign="false")
    rc, text = h.said("doctor", installer=inst)
    check(command(text, "user.name is not set, so git refuses every commit - run: ")
          == ["git", "config", "--file", h.local, "user.name", "Full Name"],
          "doctor's user.name fix names config.local as one shell word (%r)" % text)
    check(command(text, "user.email is not set, so git refuses every commit - run: ")
          == ["git", "config", "--file", h.local, "user.email", "<your", "email>"],
          "doctor's user.email fix names config.local as one shell word (%r)" % text)
    # A host that signs: the fixes name the installer.
    h.set(user__email="me@example.com")
    rc, text = h.said("doctor", installer=inst)
    check(command(text, "user.name is not set, so git refuses every commit - run: ")
          == [inst, "identity", "--name", "Full Name"],
          "doctor's user.name fix names the installer as one shell word (%r)" % text)
    rc, text = h.said("identity", installer=inst)
    check(command(text, "user.name is not set - run: ") == [inst, "identity", "--name", ACCOUNT_NAME],
          "identity's missing-name line names the installer as one shell word (%r)" % text)
    slashed = os.path.join(h.home, "dot\\files", "install.sh")
    rc, text = h.said("identity", installer=slashed)
    check(command(text, "user.name is not set - run: ") == [slashed, "identity", "--name", ACCOUNT_NAME],
          "a printable installer path holding a backslash runs as printed (%r)" % text)
    # Two identities for the agent's key: the fix sets user.email first.
    with open(h.signers, "w") as fh:
        fh.write("a@example.com %s\nb@example.com %s\n" % (K1, K1))
    h.set()
    rc, text = h.said("identity", installer=inst)
    check(rc == 1 and command(text, "identity:   git config --file ")[:1] == [h.local],
          "identity's user.email fix names config.local as one shell word (%r)" % text)
    # auto's one line: the suffix names the installer the way the lines do,
    # so a line that already names it gets no second pointer. A key is set,
    # so the host does not fail closed.
    h.set(user__signingkey="key::ssh-ed25519 AAAA")
    rc, text = h.said("auto", installer=inst)
    check(rc == 1 and text.count("\n") == 1 and text.endswith(" (details: %s identity)\n" % shlex.quote(inst)),
          "auto's details suffix names the installer as one shell word (%r)" % text)
    os.environ["SSH_CONNECTION"] = "10.0.0.1 22 10.0.0.2 22"
    rc, text = h.said("auto", installer=inst)
    del os.environ["SSH_CONNECTION"]
    check(rc == 1 and text.count("\n") == 1 and "(details:" not in text
          and "- run %s identity to set it on purpose" % shlex.quote(inst) in text,
          "auto's SSH line names the installer once, as one shell word (%r)" % text)


def killed_units(mod, scratch):
    """A run killed while `ssh-keygen -Q` checks a key against a KRL removes
    the key file it wrote for that, and git's empty directory, and then
    dies of the signal it got. In a child, since that is the point; the
    ssh-keygen it runs is a stub that says it started and then waits."""
    bindir = os.path.join(scratch, "killed-bin")
    os.mkdir(bindir)
    started = os.path.join(scratch, "killed-started")
    stub(bindir, "ssh-keygen", 'touch "%s"\nexec sleep 30\n' % started)
    child = (
        "import importlib.util, sys\n"
        "spec = importlib.util.spec_from_file_location('m', sys.argv[1])\n"
        "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
        "def run(host, mode, name, report_stale, verbose=False):\n"
        "    m.git(['config', '--get', 'user.email'])\n"
        "    m.krl_revokes(sys.argv[3], m.parse_key(sys.argv[4]))\n"
        "    return 0, None\n"
        "m.run = run\n"
        "sys.exit(m.entry(['--config-local', sys.argv[2], '--mode', 'check']))\n"
    )
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        tmpdir = os.path.join(scratch, "killed-tmp-%d" % sig)
        os.mkdir(tmpdir, 0o700)
        if os.path.exists(started):
            os.remove(started)
        env = dict(os.environ, HOME=scratch, TMPDIR=tmpdir, PATH=bindir + os.pathsep + os.environ["PATH"])
        p = subprocess.Popen([sys.executable, "-I", "-B", "-c", child, mod.__file__,
                              os.path.join(scratch, "c.local"), os.devnull, K1],
                             env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # Bounded: 20 s for the stub to start, then 20 s for the child to go.
        for _ in range(200):
            if os.path.exists(started) or p.poll() is not None:
                break
            time.sleep(0.1)
        left_mid = sorted(os.listdir(tmpdir))
        p.send_signal(sig)
        try:
            _, err = p.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            p.kill()
            _, err = p.communicate()
        left = os.listdir(tmpdir)
        check(any(n.endswith(".pub") for n in left_mid) and p.returncode == -sig and b"Traceback" not in err
              and left == [],
              "killed by %s mid ssh-keygen -Q, a run removes its KRL key and git's directory and dies of it "
              "(rc %s, held %r, left %r, %r)" % (signal.Signals(sig).name, p.returncode, left_mid, left, err))
    # Deterministic: a signal that arrives the instant a temporary file or
    # directory exists, before the code that made it has recorded it (the
    # creating call, patched, signals the process and only then returns).
    # The record must still be made, and the file removed.
    created = (
        "import importlib.util, os, signal, sys, tempfile\n"
        "spec = importlib.util.spec_from_file_location('m', sys.argv[1])\n"
        "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
        "real = {'mkstemp': tempfile.mkstemp, 'mkdtemp': tempfile.mkdtemp}\n"
        "def killing(name):\n"
        "    def make(*a, **k):\n"
        "        made = real[name](*a, **k)\n"
        "        if k.get('prefix') == sys.argv[4]:\n"
        "            os.kill(os.getpid(), signal.SIGTERM)\n"
        "            (lambda: None)()  # a Python call: a pending handler runs here\n"
        "        return made\n"
        "    return make\n"
        "tempfile.mkstemp, tempfile.mkdtemp = killing('mkstemp'), killing('mkdtemp')\n"
        "def run(host, mode, name, report_stale, verbose=False):\n"
        "    if sys.argv[3] == 'krl':\n"
        "        m.krl_revokes(os.devnull, m.parse_key(sys.argv[5]))\n"
        "    elif sys.argv[3] == 'git':\n"
        "        m.git(['--version'])\n"
        "    else:\n"
        "        m.write_keys(sys.argv[2], [('user.name', 'Jane')])\n"
        "    return 0, None\n"
        "m.run = run\n"
        "sys.exit(m.entry(['--config-local', sys.argv[2], '--mode', 'check']))\n"
    )
    for what, prefix in (("krl", "host_identity."), ("git", "host_identity.git."),
                         ("write", ".config.local."), ("backup", ".config.local.bak.")):
        tmpdir = os.path.join(scratch, "created-tmp-" + what)
        confdir = os.path.join(scratch, "created-conf-" + what)
        os.mkdir(tmpdir, 0o700)
        os.mkdir(confdir, 0o700)
        local = os.path.join(confdir, "config.local")
        with open(local, "w") as fh:
            fh.write("[user]\n\temail = a@x\n")
        p = subprocess.run([sys.executable, "-I", "-B", "-c", created, mod.__file__, local, what, prefix, K1],
                           env=dict(os.environ, HOME=scratch, TMPDIR=tmpdir), stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        left = os.listdir(tmpdir) + [n for n in os.listdir(confdir) if n != "config.local"]
        check(p.returncode == -signal.SIGTERM and left == [] and b"Traceback" not in p.stderr,
              "a SIGTERM the instant %s's temporary file exists leaves nothing behind (rc %d, left %r, %r)"
              % (what, p.returncode, left, p.stderr))

    # A second signal while the first one unwinds is ignored, so the
    # cleanup it would interrupt still runs. The first arrives mid
    # ssh-keygen -Q (patched to signal the process), the second as the key
    # file is about to be removed (os.unlink, patched the same way).
    twice = (
        "import importlib.util, os, signal, sys\n"
        "spec = importlib.util.spec_from_file_location('m', sys.argv[1])\n"
        "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
        "first, second = int(sys.argv[3]), int(sys.argv[4])\n"
        "def killed(*a, **k):\n"
        "    os.kill(os.getpid(), first)\n"
        "real_unlink = os.unlink\n"
        "sent = []\n"
        "def unlink(path, *a, **k):\n"
        "    if not sent and path.endswith('.pub'):\n"
        "        sent.append(path)\n"
        "        os.kill(os.getpid(), second)\n"
        "        (lambda: None)()  # a Python call: a pending handler runs here\n"
        "    return real_unlink(path, *a, **k)\n"
        "def run(host, mode, name, report_stale, verbose=False):\n"
        "    m.subprocess.run, os.unlink = killed, unlink\n"
        "    m.krl_revokes(os.devnull, m.parse_key(sys.argv[5]))\n"
        "    return 0, None\n"
        "m.run = run\n"
        "sys.exit(m.entry(['--config-local', sys.argv[2], '--mode', 'check']))\n"
    )
    for first in (signal.SIGTERM, signal.SIGINT):
        for second in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            tmpdir = os.path.join(scratch, "twice-%d-%d" % (first, second))
            os.mkdir(tmpdir, 0o700)
            p = subprocess.run([sys.executable, "-I", "-B", "-c", twice, mod.__file__, os.path.join(scratch, "c.local"),
                                str(int(first)), str(int(second)), K1],
                               env=dict(os.environ, HOME=scratch, TMPDIR=tmpdir), stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
            left = os.listdir(tmpdir)
            check(p.returncode == -first and left == [] and b"Traceback" not in p.stderr,
                  "a %s during the cleanup after a %s is ignored: the key file is removed (rc %d, left %r, %r)"
                  % (signal.Signals(second).name, signal.Signals(first).name, p.returncode, left, p.stderr))

    # A signal that lands while a cleanup already runs on a normal way out
    # (no signal before it) waits for that cleanup to finish: the remover,
    # patched, signals the process first and only then removes. The process
    # still dies of the signal, after the file is gone.
    cleaning = (
        "import importlib.util, os, shutil, signal, subprocess, sys\n"
        "spec = importlib.util.spec_from_file_location('m', sys.argv[1])\n"
        "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
        "real = {'unlink': os.unlink, 'rmtree': shutil.rmtree}\n"
        "sent = []\n"
        "def killing(name):\n"
        "    def remove(path, *a, **k):\n"
        "        if not sent and os.path.basename(path).startswith(sys.argv[4]):\n"
        "            sent.append(path)\n"
        "            os.kill(os.getpid(), signal.SIGTERM)\n"
        "            (lambda: None)()  # a Python call: a pending handler runs here\n"
        "        return real[name](path, *a, **k)\n"
        "    return remove\n"
        "os.unlink, m.shutil.rmtree = killing('unlink'), killing('rmtree')\n"
        "def run(host, mode, name, report_stale, verbose=False):\n"
        "    if sys.argv[3] == 'krl':\n"
        "        m.subprocess.run = lambda *a, **k: subprocess.CompletedProcess(a, 0)\n"
        "        m.krl_revokes(os.devnull, m.parse_key(sys.argv[5]))\n"
        "    elif sys.argv[3] == 'git':\n"
        "        m.git(['--version'])\n"
        "    elif sys.argv[3] == 'write':\n"
        "        m.git = lambda args: (1, '', 'refused')  # the staged file is then removed\n"
        "        m.write_keys(sys.argv[2], [('user.name', 'Jane')])\n"
        "    else:\n"
        "        m.write_keys(sys.argv[2], [('user.name', 'Jane')])\n"
        "    return 0, None\n"
        "m.run = run\n"
        "sys.exit(m.entry(['--config-local', sys.argv[2], '--mode', 'check']))\n"
    )
    for what, prefix in (("krl", "host_identity."), ("git", "host_identity.git."),
                         ("write", ".config.local."), ("backup", ".config.local.bak.")):
        tmpdir = os.path.join(scratch, "cleaning-tmp-" + what)
        confdir = os.path.join(scratch, "cleaning-conf-" + what)
        os.mkdir(tmpdir, 0o700)
        os.mkdir(confdir, 0o700)
        local = os.path.join(confdir, "config.local")
        with open(local, "w") as fh:
            fh.write("[user]\n\temail = a@x\n")
        p = subprocess.run([sys.executable, "-I", "-B", "-c", cleaning, mod.__file__, local, what, prefix, K1],
                           env=dict(os.environ, HOME=scratch, TMPDIR=tmpdir), stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        # The backup case finishes its .bak before the signal: that one stays.
        left = os.listdir(tmpdir) + [n for n in os.listdir(confdir) if n not in ("config.local", "config.local.bak")]
        check(p.returncode == -signal.SIGTERM and left == [] and b"Traceback" not in p.stderr,
              "a SIGTERM while %s's cleanup runs on a normal way out waits for it (rc %d, left %r, %r)"
              % (what, p.returncode, left, p.stderr))

    # A signal on a normal way out that lands just before the cleanup holds
    # the signals: _Held, patched, signals the process the first time it is
    # entered while the temporary file or directory exists, before the real
    # one blocks anything. The cleanup never runs, so entry() must remove
    # what is left on its way out.
    before = (
        "import importlib.util, os, signal, subprocess, sys\n"
        "spec = importlib.util.spec_from_file_location('m', sys.argv[1])\n"
        "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
        "what = sys.argv[3]\n"
        "dirs = (os.environ['TMPDIR'], os.path.dirname(sys.argv[2]))\n"
        "def made(n):\n"
        "    if what == 'krl':\n"
        "        return n.endswith('.pub')\n"
        "    if what == 'git':\n"
        "        return n.startswith('host_identity.git.')\n"
        "    if what == 'write':\n"
        "        return n.startswith('.config.local.') and not n.startswith('.config.local.bak.')\n"
        "    return n.startswith('.config.local.bak.')\n"
        "sent = []\n"
        "Base = m._Held\n"
        "class Held(Base):\n"
        "    def __enter__(self):\n"
        "        if not sent and any(made(n) for d in dirs for n in os.listdir(d)):\n"
        "            sent.append(1)\n"
        "            os.kill(os.getpid(), signal.SIGTERM)\n"
        "            (lambda: None)()  # a Python call: a pending handler runs here\n"
        "        return Base.__enter__(self)\n"
        "m._Held = Held\n"
        "def run(host, mode, name, report_stale, verbose=False):\n"
        "    if what == 'krl':\n"
        "        m.subprocess.run = lambda *a, **k: subprocess.CompletedProcess(a, 0)\n"
        "        m.krl_revokes(os.devnull, m.parse_key(sys.argv[4]))\n"
        "    elif what == 'git':\n"
        "        m.git(['--version'])\n"
        "    elif what == 'write':\n"
        "        m.git = lambda args: (1, '', 'refused')  # the staged file is then removed\n"
        "        m.write_keys(sys.argv[2], [('user.name', 'Jane')])\n"
        "    else:\n"
        "        m.write_keys(sys.argv[2], [('user.name', 'Jane')])\n"
        "    return 0, None\n"
        "m.run = run\n"
        "sys.exit(m.entry(['--config-local', sys.argv[2], '--mode', 'check']))\n"
    )
    for what in ("krl", "git", "write", "backup"):
        tmpdir = os.path.join(scratch, "before-tmp-" + what)
        confdir = os.path.join(scratch, "before-conf-" + what)
        os.mkdir(tmpdir, 0o700)
        os.mkdir(confdir, 0o700)
        local = os.path.join(confdir, "config.local")
        with open(local, "w") as fh:
            fh.write("[user]\n\temail = a@x\n")
        p = subprocess.run([sys.executable, "-I", "-B", "-c", before, mod.__file__, local, what, K1],
                           env=dict(os.environ, HOME=scratch, TMPDIR=tmpdir), stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        left = os.listdir(tmpdir) + [n for n in os.listdir(confdir) if n not in ("config.local", "config.local.bak")]
        check(p.returncode == -signal.SIGTERM and left == [] and b"Traceback" not in p.stderr,
              "a SIGTERM just before %s's cleanup holds the signals leaves nothing behind (rc %d, left %r, %r)"
              % (what, p.returncode, left, p.stderr))

    # Two different signals pending at once: the first unwinds, the second is
    # ignored quietly, with no "Exception ignored" report of a race. Both are
    # sent while blocked, so both are pending when they are let through.
    both = (
        "import importlib.util, os, signal, sys\n"
        "spec = importlib.util.spec_from_file_location('m', sys.argv[1])\n"
        "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
        "def run(host, mode, name, report_stale, verbose=False):\n"
        "    m.git(['--version'])\n"
        "    old = signal.pthread_sigmask(signal.SIG_BLOCK, m.UNWINDING)\n"
        "    os.kill(os.getpid(), int(sys.argv[3]))\n"
        "    os.kill(os.getpid(), int(sys.argv[4]))\n"
        "    signal.pthread_sigmask(signal.SIG_SETMASK, old)\n"
        "    (lambda: None)()  # a Python call: the pending handlers run here\n"
        "    return 0, None\n"
        "m.run = run\n"
        "sys.exit(m.entry(['--config-local', sys.argv[2], '--mode', 'check']))\n"
    )
    for first, second in ((signal.SIGHUP, signal.SIGTERM), (signal.SIGINT, signal.SIGTERM),
                          (signal.SIGHUP, signal.SIGINT)):
        tmpdir = os.path.join(scratch, "both-%d-%d" % (first, second))
        os.mkdir(tmpdir, 0o700)
        p = subprocess.run([sys.executable, "-I", "-B", "-c", both, mod.__file__, os.path.join(scratch, "c.local"),
                            str(int(first)), str(int(second))],
                           env=dict(os.environ, HOME=scratch, TMPDIR=tmpdir), stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        # The lower-numbered signal is handled first.
        check(p.returncode == -min(first, second) and os.listdir(tmpdir) == [] and p.stderr == b"",
              "a %s and a %s pending at once: the run unwinds by one, cleans up, and says nothing (rc %d, %r)"
              % (signal.Signals(first).name, signal.Signals(second).name, p.returncode, p.stderr))

    # A termination is a BaseException, as KeyboardInterrupt is: no `except
    # Exception` on the way out swallows it.
    check(issubclass(mod.Terminated, BaseException) and not issubclass(mod.Terminated, Exception),
          "Terminated is a BaseException and not an Exception")

    # A SIGTERM the caller ignores (nohup does that for SIGHUP) stays ignored.
    ignored = (
        "import importlib.util, signal, sys\n"
        "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "spec = importlib.util.spec_from_file_location('m', sys.argv[1])\n"
        "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
        "m.run = lambda *a, **k: (0 if signal.getsignal(signal.SIGTERM) == signal.SIG_IGN else 1, None)\n"
        "sys.exit(m.entry(['--config-local', sys.argv[2], '--mode', 'check']))\n"
    )
    p = subprocess.run([sys.executable, "-I", "-B", "-c", ignored, mod.__file__, os.path.join(scratch, "c.local")],
                       env=dict(os.environ, HOME=scratch), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, timeout=60)
    check(p.returncode == 0, "a SIGTERM the caller ignores stays ignored (rc %d, %r)" % (p.returncode, p.stderr))


# --- every value a message puts in is escaped: a static check ---------------
#
# The escaping rule of lib/host_identity.py (_shown(), quoted(),
# shell_word()) holds only where each call site applies it, and the end-to-end
# checks reach only the branches a test stages. So, over the whole file:
#
# 1. Every operand put into a string by `%`, by an f-string, or by `+` next
#    to a literal holding a space, and every argument handed to a printer
#    (SINKS), is safe: a constant; an operand a numeric `%` conversion
#    formats (a string there raises, it never prints); a call to an escaper
#    (SAFE_CALLS) or to a message function (MESSAGE_FUNCS); str(), _bare(),
#    _untailed(), sorted(), a slice, a join or a container of safe operands;
#    a conditional or an `or` whose branches are; or a name in LITERAL_NAMES
#    or an attribute in LITERAL_ATTRS.
# 2. Those names are trusted for the data they hold, not their spelling:
#    every binding of one (an assignment, `+=`, a loop or comprehension
#    target, an append) is given a safe value by rule 1, or the message part
#    of what a message function returns. A parameter with such a name is
#    given a safe value at every call of its function, which is only ever
#    called by its name. A `with` target or an import never binds one, and an
#    `except` binds one only for Refusal, whose message is a printer's
#    argument. A template name (TEMPLATES) is only ever bound to a literal.
# 3. Every value a message function returns (its message part) is safe; an
#    attribute it returns counts when every value ever stored in it is one.
# 4. A printer is only ever called by its name, never aliased, passed on or
#    looked up by a string. A standard stream is only ever named as
#    `sys.stderr` or `sys.stdout` (never imported from sys, never with sys
#    renamed) and only to call its write() or as print()'s file=, so no
#    alias, writelines() or buffer reaches it; os.write() and os.writev()
#    are printers of their data arguments.
# 5. A message function is matched by how it is called: one in
#    MESSAGE_FUNCS by its bare name only, one in MESSAGE_METHODS as a method
#    only, and each is defined that way, so `subprocess.run()` is not run().
#    An attribute counts as a memo (rule 3) only when every store to it is
#    a plain assignment; setattr() and globals() are never called.
#
# Not covered, so kept by review: a trusted container changed through an
# alias of it (`l = lines; l.append(p)`), and a file other than the
# standard streams written to directly.
#
# A name or a function joins a list here only with the reason it holds
# message text, and the rules above then hold every binding of it to that.

# Escapers, and calls whose result is safe by what it computes. Matched by
# a bare name only: `re.escape(path)` is not escape(path).
SAFE_CALLS = {
    "_shown", "quoted", "shell_word", "escape",
    "fingerprint",  # SHA256:<base64>, computed here
    "len", "int",
}
SAFE_DOTTED = {"platform.python_version"}  # digits and dots
# Functions whose return value is message text this module built: None for
# the whole value, else the indexes of the message parts of the tuple they
# return. Each return of each def of that name is checked. A module-level
# function is matched by a call to its bare name, a method (MESSAGE_METHODS)
# by a call to its attribute name (host.agent()), so these names stay
# distinctive.
MESSAGE_FUNCS = {
    "missing_name_line": None,
    "headline": None,  # one of the captured warn() lines
    "_grouped": None,  # the captured warn() lines, each hint joined to its line
    "_capture": (1,),  # (result, the warn() lines it collected)
    "git_isolate": None, "_isolate": None,  # why git cannot be isolated
    "overridden_line": None,
    "entry_usable_now": (1,),  # (usable, why not)
    "stale_reason": (2,),  # (email, path, why)
    "gitconfig_finding": (1,),  # (level, text)
    "auto": (1,), "run": (1,),  # (exit status, the one line's suffix)
    "select": (1,),  # (chosen, the lines that say why none was)
    "read_small_file": (1,), "load_revocation": (1,),  # (data, why not)
}
MESSAGE_METHODS = {
    "why_no_candidate": None, "why_invalid": None,
    "agent": (1,), "_read_agent": (1,),  # (keys, why not)
    "revocation": (1,), "_read_revocation": (1,),  # (path, why not)
    "locate_signers": (1, 2),  # (path, which config named it, why not)
    "signers": (1, 3), "_read_signers": (1, 3),  # (path, source, entries, why not)
}
LITERAL_NAMES = {
    # A message, or a list of messages, this module built: a reason, a
    # refusal, a joined override list, an already-shell_word() installer, a
    # doctor finding, a captured warning, the one line's suffix.
    "why", "reason", "reasons", "what", "inst", "finding", "said", "lines", "consequence",
    "_captured", "outer", "folded", "kept", "tag_kept", "refusal",
    # Words from this module's literals.
    "UNDECIDED", "source", "tail", "how", "verb", "env_name", "nums",
}
# os.strerror() text and os.pathsep come from the C library, not a value; a
# Doctor's found list holds what its printers were handed; a GitPlace's
# refusal is what _isolate() returned.
LITERAL_ATTRS = {"strerror", "pathsep", "found", "refusal"}
# Not checked inside: the escapers format characters, not values, and the
# printers print the message they are handed, checked where it is built.
SKIPPED = {"escape", "quoted", "_shown", "shell_word", "warn", "note", "log", "ok", "info", "problem"}
# What prints a message: warn(), note(), log(), print(), a doctor finding,
# and a Refusal, whose text is shown later through str().
SINK_FUNCS = {"warn", "note", "log", "print", "Refusal"}
SINK_METHODS = {"ok", "info", "problem"}
SINK_STREAMS = {"sys.stderr", "sys.stdout"}
STREAM_NAMES = {"stderr", "stdout", "__stderr__", "__stdout__"}
STREAMS = set("sys." + n for n in STREAM_NAMES)
# Printers of every argument after the first (a file descriptor).
SINK_DOTTED = {"os.write", "os.writev"}
NOT_MESSAGE_KEYWORDS = {"signing"}  # Doctor.problem(signing=...) is a flag
# Message templates held in a name and filled with `%` later.
TEMPLATES = {"form", "FAIL_CLOSED", "name_local", "name_step", "email_local", "email_step"}
# A conversion that only formats a number: a string given to it raises.
_NUMERIC = set("diouxXeEfFgG")
_SPEC = re.compile(r"%(?:\([^)]*\))?[-#0 +]*(?:\*|\d+)?(?:\.(?:\*|\d+))?[hlL]?(.)")


def _conversions(template):
    """The conversion letter of each operand TEMPLATE takes, in order."""
    return [m.group(1) for m in _SPEC.finditer(template) if m.group(1) != "%"]


def _dotted(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        head = _dotted(node.value)
        return head and head + "." + node.attr
    return None


def _callee(node):
    """The name a call is made by: a bare name, or a method's attribute."""
    f = node.func
    return f.id if isinstance(f, ast.Name) else f.attr if isinstance(f, ast.Attribute) else None


def _message_call(node, index):
    """Whether NODE calls a message function whose message is INDEX of what
    it returns (None: the whole value): a MESSAGE_FUNCS one by its bare
    name, a MESSAGE_METHODS one as a method."""
    if not isinstance(node, ast.Call):
        return False
    f = node.func
    table = MESSAGE_FUNCS if isinstance(f, ast.Name) else MESSAGE_METHODS if isinstance(f, ast.Attribute) else {}
    if _callee(node) not in table:
        return False
    parts = table[_callee(node)]
    return parts is None if index is None else parts is not None and index in parts


def _str_literal(node):
    if isinstance(node, ast.IfExp):
        return _str_literal(node.body) and _str_literal(node.orelse)
    return isinstance(node, ast.Constant) and isinstance(node.value, str)


def _safe(node):
    if isinstance(node, ast.Constant):
        return True
    if isinstance(node, ast.Name):
        return node.id in LITERAL_NAMES
    if isinstance(node, ast.Attribute):
        return node.attr in LITERAL_ATTRS
    if isinstance(node, ast.IfExp):
        return _safe(node.body) and _safe(node.orelse)
    if isinstance(node, ast.BoolOp):
        return all(_safe(v) for v in node.values)
    if isinstance(node, (ast.Tuple, ast.List, ast.Set)):
        return all(_safe(e) for e in node.elts)
    if isinstance(node, ast.Subscript):
        return _safe(node.value)  # a part of a safe value
    if isinstance(node, (ast.GeneratorExp, ast.ListComp)):
        return _safe(node.elt)  # its targets are bindings, checked as such
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mod):
        # Checked as a format of its own.
        return _str_literal(node.left) or isinstance(node.left, ast.Name) and node.left.id in TEMPLATES
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        return _safe(node.left) and _safe(node.right)
    if isinstance(node, ast.Call):
        if isinstance(node.func, ast.Name):
            name = node.func.id
            if name in SAFE_CALLS:
                return True
            if name in ("str", "_bare", "_untailed", "sorted") and len(node.args) == 1:
                return _safe(node.args[0])
        elif _dotted(node.func) in SAFE_DOTTED:
            return True
        elif (isinstance(node.func, ast.Attribute) and node.func.attr == "join" and len(node.args) == 1
              and isinstance(node.func.value, ast.Constant)):
            return _safe(node.args[0])
        return _message_call(node, None)
    return False


def _formatted(node):
    """The operands a `%` format puts in that may be text: those a numeric
    conversion takes are left out."""
    right = node.right
    ops = list(right.elts) if isinstance(right, ast.Tuple) else [right]
    if isinstance(node.left, ast.Constant) and isinstance(node.left.value, str):
        kinds = _conversions(node.left.value)
        if len(kinds) == len(ops):
            return [op for op, kind in zip(ops, kinds) if kind not in _NUMERIC]
    return ops


def _is_sink(node):
    """A call that prints its arguments, or records them to print."""
    if not isinstance(node, ast.Call):
        return False
    f = node.func
    return (isinstance(f, ast.Name) and f.id in SINK_FUNCS
            or _dotted(f) in SINK_DOTTED
            or isinstance(f, ast.Attribute) and (f.attr in SINK_METHODS | SINK_FUNCS
                                                 or f.attr == "write" and _dotted(f.value) in SINK_STREAMS))


def unescaped_values(source):
    """[(line, what)] for every operand that may put an unescaped value into
    a string or a printer, and every binding, return or printer reference
    that breaks the rules above."""
    tree = ast.parse(source)
    found = []
    defs = {}  # name: [FunctionDef]
    stored = {}  # attribute name: [values stored in it]
    for n in ast.walk(tree):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
            defs.setdefault(n.name, []).append(n)
        if isinstance(n, ast.Assign):
            for t in n.targets:
                if isinstance(t, ast.Attribute):
                    stored.setdefault(t.attr, []).append(n.value)
                elif isinstance(t, ast.Tuple):  # a, self.x = ...: not a memo
                    for e in t.elts:
                        if isinstance(e, ast.Attribute):
                            stored.setdefault(e.attr, []).append(None)
        elif isinstance(n, (ast.AugAssign, ast.AnnAssign)) and isinstance(n.target, ast.Attribute):
            stored.setdefault(n.target.attr, []).append(None)  # self.x += ...: not a memo
    # Rule 5: each message function is defined the way it is matched.
    for cls in [n for n in ast.walk(tree) if isinstance(n, ast.ClassDef)]:
        for fn in cls.body:
            if isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)) and fn.name in MESSAGE_FUNCS:
                found.append((fn.lineno, "message function %s defined as a method" % fn.name))
    for fn in tree.body:
        if isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)) and fn.name in MESSAGE_METHODS:
            found.append((fn.lineno, "message method %s defined as a function" % fn.name))
    # Rule 4: where a standard stream may be named.
    stream_ok = set()
    for n in ast.walk(tree):
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "write":
            stream_ok.add(n.func.value)
        if isinstance(n, ast.Call) and _callee(n) == "print":
            stream_ok.update(k.value for k in n.keywords if k.arg == "file")
    # Functions with a parameter that carries a trusted name: checked at
    # every call (rule 2).
    trusted_params = {}
    for name, fns in defs.items():
        for fn in fns:
            a = fn.args
            params = [x.arg for x in a.posonlyargs + a.args]
            if any(p in LITERAL_NAMES for p in params + [x.arg for x in a.kwonlyargs]):
                trusted_params[name] = fn

    def bad(node, what=None):
        found.append((getattr(node, "lineno", 0), what or ast.get_source_segment(source, node)))

    def seg(node):
        return ast.get_source_segment(source, node)

    def operands(node):
        if isinstance(node, ast.Call) and _dotted(node.func) in SINK_DOTTED:
            return list(node.args[1:])
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mod):
            left = node.left
            if not (_str_literal(left) or isinstance(left, ast.Name) and left.id in TEMPLATES):
                return [left]  # a format whose template this check cannot see
            return _formatted(node)
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            sides = (node.left, node.right)
            if any(isinstance(x, ast.Constant) and isinstance(x.value, str) and len(x.value) > 1 and " " in x.value
                   for x in sides):
                return [x for x in sides if not isinstance(x, ast.Constant)]
            return []
        if _is_sink(node):
            return list(node.args) + [k.value for k in node.keywords if k.arg not in NOT_MESSAGE_KEYWORDS]
        if isinstance(node, ast.JoinedStr):
            return [v.value for v in node.values if isinstance(v, ast.FormattedValue)]
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "format" \
                and isinstance(node.func.value, ast.Constant):
            return [node.func.value]  # str.format() is not used: say so if it ever is
        return []

    def literal(target):
        """Whether TARGET binds a trusted name (or a part of one)."""
        if isinstance(target, ast.Name):
            return target.id in LITERAL_NAMES
        if isinstance(target, ast.Attribute):
            return target.attr in LITERAL_ATTRS
        if isinstance(target, (ast.Subscript, ast.Starred)):
            return literal(target.value)
        if isinstance(target, (ast.Tuple, ast.List)):
            return any(literal(e) for e in target.elts)
        return False

    def bind(target, value, at):
        if isinstance(target, ast.Name) and target.id in TEMPLATES:
            if not _str_literal(value):
                bad(at, "template %s = %s" % (target.id, seg(value)))
            return
        if isinstance(target, (ast.Tuple, ast.List)):
            for e in target.elts:
                if isinstance(e, ast.Name) and e.id in TEMPLATES:
                    bad(at, "template %s from %s" % (e.id, seg(value)))
        if not literal(target):
            return
        if isinstance(value, ast.IfExp):
            bind(target, value.body, at)
            bind(target, value.orelse, at)
            return
        if isinstance(target, (ast.Name, ast.Attribute, ast.Subscript)):
            if not (_safe(value) or memo(value, None)):
                bad(at, "%s = %s" % (seg(target), seg(value)))
            return
        if isinstance(target, (ast.Tuple, ast.List)):
            if isinstance(value, (ast.Tuple, ast.List)) and len(value.elts) == len(target.elts):
                for t, v in zip(target.elts, value.elts):
                    bind(t, v, at)
                return
            for i, t in enumerate(target.elts):
                if literal(t) and not (isinstance(t, ast.Name) and _message_call(value, i)):
                    bad(at, "%s from %s" % (seg(t), seg(value)))
            return
        bad(at)  # a starred target

    def bind_each(target, iterable, at):
        """TARGET bound to each element of ITERABLE in turn."""
        if isinstance(iterable, (ast.Tuple, ast.List)):
            for e in iterable.elts:
                bind(target, e, at)
        elif literal(target) and not _safe(iterable):
            bad(at, "%s in %s" % (seg(target), seg(iterable)))

    def memo(value, index):
        """Whether VALUE is an attribute that only ever holds None or what a
        message function returns (at INDEX)."""
        if not isinstance(value, ast.Attribute) or value.attr not in stored:
            return False
        return all(v is not None and (isinstance(v, ast.Constant) and v.value is None or _message_call(v, index))
                   for v in stored[value.attr])

    def returned_ok(v, index):
        if isinstance(v, ast.IfExp):
            return returned_ok(v.body, index) and returned_ok(v.orelse, index)
        if memo(v, index) or _message_call(v, index):
            return True
        if index is None:
            return _safe(v)
        if isinstance(v, ast.Constant) and v.value is None:
            return True
        return isinstance(v, ast.Tuple) and len(v.elts) > index and _safe(v.elts[index])

    def returns(fn, parts):
        for node in ast.walk(fn):
            if isinstance(node, ast.Return) and node.value is not None:
                if not all(returned_ok(node.value, i) for i in (parts if parts is not None else (None,))):
                    bad(node, "%s returns %s" % (fn.name, seg(node.value)))

    def call_args(call, fn):
        """[(parameter, value)] a call passes to FN, or None when it cannot
        be told (a *args or **kwargs at the call)."""
        a = fn.args
        params = [x.arg for x in a.posonlyargs + a.args]
        if params[:1] == ["self"] and isinstance(call.func, ast.Attribute):
            params = params[1:]
        if any(isinstance(x, ast.Starred) for x in call.args) or any(k.arg is None for k in call.keywords):
            return None
        given = dict(zip(params, call.args))
        given.update((k.arg, k.value) for k in call.keywords)
        defaults = dict(zip(params[len(params) - len(a.defaults):], a.defaults))
        defaults.update((x.arg, d) for x, d in zip(a.kwonlyargs, a.kw_defaults) if d is not None)
        return [(p, given.get(p, defaults.get(p))) for p in params + [x.arg for x in a.kwonlyargs]]

    def visit(node, skip, called):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            skip = skip or node.name in SKIPPED
            if node.name in MESSAGE_FUNCS:
                returns(node, MESSAGE_FUNCS[node.name])
            elif node.name in MESSAGE_METHODS:
                returns(node, MESSAGE_METHODS[node.name])
        if isinstance(node, ast.Lambda) or isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) \
                and node.name not in trusted_params:
            a = node.args
            for arg in a.posonlyargs + a.args + a.kwonlyargs + [x for x in (a.vararg, a.kwarg) if x]:
                if arg.arg in LITERAL_NAMES or arg.arg in TEMPLATES:
                    bad(node, "parameter %s" % arg.arg)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in trusted_params:
            a = node.args
            for arg in [x for x in (a.vararg, a.kwarg) if x]:
                if arg.arg in LITERAL_NAMES:
                    bad(node, "parameter %s" % arg.arg)
        if isinstance(node, ast.Call) and _callee(node) in trusted_params:
            fn = trusted_params[_callee(node)]
            pairs = call_args(node, fn)
            if pairs is None:
                bad(node, "%s called with arguments this check cannot match" % fn.name)
            else:
                for p, v in pairs:
                    if p in LITERAL_NAMES and (v is None or not _safe(v)):
                        bad(node, "%s(%s=%s)" % (fn.name, p, v is not None and seg(v)))
        # Rule 4, checked even in SKIPPED bodies: a printer, or a function
        # with a trusted parameter, used other than by a call to its name.
        if node not in called:
            if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load) and (
                    node.id in SINK_FUNCS or node.id in trusted_params):
                bad(node, "%s used, not called" % node.id)
            if isinstance(node, ast.Attribute) and (node.attr in SINK_METHODS | SINK_FUNCS
                                                    or node.attr in trusted_params
                                                    or _dotted(node) in SINK_DOTTED
                                                    or node.attr == "write" and _dotted(node.value) in SINK_STREAMS):
                bad(node, "%s used, not called" % seg(node))
        if isinstance(node, ast.Attribute) and _dotted(node) in STREAMS and node not in stream_ok:
            bad(node, "%s used other than by write() or print(file=)" % seg(node))
        if isinstance(node, ast.Import) and any(a.name == "sys" and a.asname for a in node.names):
            bad(node, "sys imported under another name")
        if isinstance(node, ast.ImportFrom) and node.module in ("sys", "os") and any(
                a.name in STREAM_NAMES or a.name in ("write", "writev") for a in node.names):
            bad(node, "a stream or os.write imported by name")
        if isinstance(node, ast.Call) and _callee(node) in ("setattr", "globals"):
            bad(node, "%s() called" % _callee(node))
        if isinstance(node, ast.Call) and _callee(node) == "getattr" and any(
                isinstance(x, ast.Constant) and (x.value in SINK_FUNCS | SINK_METHODS or x.value == "write")
                for x in node.args):
            bad(node, "a printer looked up by name")
        if isinstance(node, ast.Call):
            called = called | {node.func}
        if isinstance(node, ast.ExceptHandler) and node.type is not None:
            # Caught, not raised: naming the class there prints nothing.
            called = called | {node.type} | set(getattr(node.type, "elts", ()))
        if not skip:
            for op in operands(node):
                if not _safe(op):
                    bad(op)
            if isinstance(node, ast.Assign):
                for t in node.targets:
                    bind(t, node.value, node)
            elif isinstance(node, (ast.AnnAssign, ast.NamedExpr)) and node.value is not None:
                bind(node.target, node.value, node)
            elif isinstance(node, ast.AugAssign):
                if isinstance(node.target, ast.Name) and node.target.id in TEMPLATES:
                    bad(node, "template %s changed" % node.target.id)
                bind(node.target, node.value, node)
            elif isinstance(node, (ast.For, ast.AsyncFor)):
                bind_each(node.target, node.iter, node)
            elif isinstance(node, ast.comprehension):
                bind_each(node.target, node.iter, node.target)
            elif isinstance(node, ast.withitem) and node.optional_vars is not None and literal(node.optional_vars):
                bad(node.optional_vars)
            elif isinstance(node, ast.ExceptHandler) and node.name in LITERAL_NAMES | TEMPLATES:
                if not (isinstance(node.type, ast.Name) and node.type.id == "Refusal"):
                    bad(node, "except ... as %s" % node.name)
            elif isinstance(node, (ast.Import, ast.ImportFrom)):
                for alias in node.names:
                    if (alias.asname or alias.name) in LITERAL_NAMES | TEMPLATES:
                        bad(node)
            elif (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                  and node.func.attr in ("append", "extend", "insert") and literal(node.func.value)):
                for arg in node.args[-1:]:
                    if node.func.attr == "extend":
                        bind_each(node.func.value, arg, node)
                    else:
                        bind(node.func.value, arg, node)
        for child in ast.iter_child_nodes(node):
            visit(child, skip, called)

    visit(tree, False, frozenset())
    return found


# Code that breaks the rules above and must be found, each appended to the
# module as a function of its own: a value given a trusted name, joined to
# one, or returned by a function the check does not trust; a printer
# aliased, written to directly, named by keyword, or reached as a Refusal;
# and a call that only looks like an escaper.
EVASIONS = (
    "def _x(path):\n    why = path\n    warn('x %s' % why)\n",
    "def _x(path):\n    said = 'x:' + path\n    warn(said)\n",
    "def _g(p):\n    return p\n\ndef _x(p):\n    reason = _g(p)\n    warn(reason)\n",
    "def _x(p):\n    said = p.strip()\n    warn(said)\n",
    "def _x(p):\n    lines = []\n    lines.append(p)\n    warn(lines[0])\n",
    "def _x(p):\n    for why in (p, 'x'):\n        warn(why)\n",
    "def _x(p):\n    why, reason = p, 'x'\n    warn(why)\n",
    "def _x(why):\n    warn(why)\n\ndef _y(p):\n    _x(p)\n",
    "def _x(why):\n    warn(why)\n\ndef _y(p):\n    _x(why=p)\n",
    "def _x(why):\n    warn(why)\n\ndef _y(p):\n    _capture(_x, p)\n",
    "def _x(p):\n    form = p\n    warn(form % 1)\n",
    "def _x(p):\n    if p:\n        refusal = p\n    warn(refusal)\n",
    "def _x(p):\n    w = warn\n    w(p)\n",
    "def _x(p):\n    sys.stderr.write(p)\n",
    "def _x(p):\n    print(p)\n",
    "def _x(self, p):\n    self.problem(line=p)\n",
    "def _x(p):\n    raise Refusal('bad %s' % p)\n",
    "def _x(p):\n    warn('x %s' % re.escape(p))\n",
    "def _x(p):\n    warn('x %d %s' % (1, p))\n",
    "def _x(p):\n    try:\n        pass\n    except OSError as why:\n        warn(why)\n",
    "def _x(p):\n    getattr(sys.modules[__name__], 'warn')(p)\n",
    "def _x(p):\n    e = sys.stderr\n    e.write(p)\n",
    "def _x(p):\n    sys.stderr.writelines([p])\n",
    "def _x(p):\n    sys.stdout.buffer.write(p)\n",
    "def _x(p):\n    from sys import stderr\n    stderr.write(p)\n",
    "def _x(p):\n    import sys as s\n    s.stderr.write(p)\n",
    "def _x(p):\n    os.write(2, p)\n",
    "def _x(p):\n    w = os.write\n    w(2, p)\n",
    "def _x(p):\n    _, why = subprocess.run(p)\n    warn(why)\n",
    "def _x(host, p):\n    why = host.missing_name_line(p)\n    warn(why)\n",
    "class _K(object):\n    def _m(self, p):\n        self._memo = missing_name_line(p)\n        self._memo += p\n"
    "        why = self._memo\n        warn(why)\n",
    "def _x(self, p):\n    setattr(self, 'refusal', p)\n",
    "def _x(p):\n    globals()['why'] = p\n",
)


def static_units(source):
    found = unescaped_values(source)
    check(not found, "every value lib/host_identity.py puts into a string is escaped (unescaped: %r)" % found)
    # The check cannot pass by checking nothing: each evasion is found, and
    # so is a message function made to return a raw value.
    missed = [e for e in EVASIONS if not unescaped_values(source + "\n\n" + e)]
    check(not missed, "each of the %d evasions of the escaping rule is found (missed: %r)" % (len(EVASIONS), missed))
    with_raw = source + "\n\ndef _g(p):\n    return p\n"
    MESSAGE_FUNCS["_g"] = None
    try:
        check(unescaped_values(with_raw), "a message function that returns its raw argument is found")
    finally:
        del MESSAGE_FUNCS["_g"]
    # Each escaper call site outside the escapers and printers, turned into
    # str() one at a time, is found; a call whose value is only compared
    # (suggested_name()'s test that a name prints bare) prints nothing.
    lines = source.splitlines(True)
    starts = [0]
    for line in lines:
        starts.append(starts[-1] + len(line))
    tree = ast.parse(source)
    compared = set(c for n in ast.walk(tree) if isinstance(n, ast.Compare) for c in [n.left] + n.comparators)
    skipped = [(n.lineno, n.end_lineno) for n in ast.walk(tree)
               if isinstance(n, ast.FunctionDef) and n.name in SKIPPED]
    sites = [(starts[n.lineno - 1] + n.col_offset, n.func.id) for n in ast.walk(tree)
             if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
             and n.func.id in ("_shown", "quoted", "shell_word", "escape")
             and not any(lo <= n.lineno <= hi for lo, hi in skipped) and n not in compared]
    missed = []
    for i, name in sites:
        # Byte and character offsets agree: the file's code is ASCII.
        mutant = source[:i] + "str(" + source[i + len(name) + 1:]
        if not unescaped_values(mutant):
            missed.append("%s:%d" % (name, source.count("\n", 0, i) + 1))
    counts = dict((name, sum(1 for _, n in sites if n == name)) for name in ("_shown", "quoted", "shell_word"))
    check(all(counts.values()) and not missed,
          "each escaper call site turned into str() is found (%r; missed %r)" % (counts, missed))


def main(argv):
    module, scratch = argv
    with open(module, encoding="utf-8") as fh:
        source = fh.read()
    # The Python 3.9 floor (the macOS Command Line Tools python3): newer
    # grammar would only fail on the hosts this file exists for.
    try:
        ast.parse(source, filename=module, feature_version=(3, 9))
        check(True, "lib/host_identity.py parses as Python 3.9")
    except SyntaxError as e:
        check(False, "lib/host_identity.py parses as Python 3.9: %s" % e)
    static_units(source)
    mod = load(module)
    mod.pwd = PinnedPwd()
    check(mod.account_name() == ACCOUNT_NAME, "the units run as the pinned account, never the host's")

    # --- the git environment: what is scrubbed, what survives ---------------
    saved = dict(os.environ)
    try:
        git_units(mod, scratch)
    finally:
        mod.git_release()
        mod.tempfile.tempdir = None
        os.environ.clear()
        os.environ.update(saved)

    # --- a git read that fails is said, never taken for an unset value -----
    real_git = mod.git
    mod.git = lambda args: (128, "", "fatal: bad config line 3")
    try:
        host = mod.Host(scratch, os.path.join(scratch, "config.local"), "INSTALLER")
        mod._captured = []
        ok_format = mod.require_ssh_format(host)
        said_format = mod._captured
        mod._captured = []
        reported = mod.check_signing_key(host)
        said_check = mod._captured
        included = host.includes_local()
    finally:
        mod._captured = None
        mod.git = real_git
    check(not ok_format and said_format[:1] == ["identity: cannot read gpg.format (fatal: bad config line 3) - writing nothing"],
          "require_ssh_format names git's error, not an unset gpg.format")
    check(reported and said_check == ["identity: cannot read gpg.format (fatal: bad config line 3) - user.signingkey not checked"],
          "check_signing_key names git's error instead of staying silent")
    check(included == (False, "fatal: bad config line 3"), "includes_local carries git's error, not a missing include")

    # Doctor.git() on the same failed read: git itself runs, but the
    # include.path read does not. GIT_CONFIG_GLOBAL is unset so the check
    # reaches the include test instead of stopping at a custom global.
    def only_version_runs(args):
        if args == ["--version"]:
            return 0, "git version 2.45.0", ""
        return 128, "", "fatal: bad config line 3"

    mod.git = only_version_runs
    saved_global = os.environ.pop("GIT_CONFIG_GLOBAL", None)
    try:
        host = mod.Host(scratch, os.path.join(scratch, "config.local"), "INSTALLER")
        d = mod.Doctor(host)
        d.git()
    finally:
        mod.git = real_git
        if saved_global is not None:
            os.environ["GIT_CONFIG_GLOBAL"] = saved_global
    check(("problem", "cannot read include.path (fatal: bad config line 3) - check the file "
           "git -C ~ config --show-origin --get-all include.path names") in d.found
          and not any(text.startswith("no [include] reaches") for _, text in d.found),
          "doctor says it cannot read include.path, not that no include exists")

    def show_origin_fails(args):
        if "--show-origin" in args:
            return 128, "", "fatal: bad config line 9"
        if args[-1] == "gpg.format":
            return 0, "ssh", ""
        if args[-1] == "user.email":
            return 0, "me@example.com", ""
        return 1, "", ""

    mod.git = show_origin_fails
    try:
        host = mod.Host(scratch, os.path.join(scratch, "config.local"), "INSTALLER")
        mod._captured = []
        reported = mod.check_signing_key(host)
        said_check = mod._captured
        mod._captured = []
        rc = mod.rotate(host)
        said_rotate = mod._captured
    finally:
        mod._captured = None
        mod.git = real_git
    check(reported and said_check == ["identity: cannot read user.signingkey (fatal: bad config line 9) - not checked"],
          "check_signing_key names a failed user.signingkey read instead of taking it for unset")
    check(rc == 1 and said_rotate == ["identity: --rotate: cannot read user.signingkey (fatal: bad config line 9) - writing nothing"],
          "--rotate names a failed user.signingkey read instead of 'not set'")

    # --- keys: types, exact blob structure, agent noise ---------------------
    for kind in ("rsa", "ecdsa"):
        path = os.path.join(scratch, kind)
        subprocess.run(["ssh-keygen", "-q", "-t", kind, "-N", "", "-f", path], check=True,
                       stdin=subprocess.DEVNULL)
        with open(path + ".pub") as fh:
            check(mod.parse_key(fh.read()) is not None, "an ssh-keygen %s public key parses" % kind)
    sk_ed = key_line(b"sk-ssh-ed25519@openssh.com", b"\x01" * 32, b"ssh:")
    sk_ec = key_line(b"sk-ecdsa-sha2-nistp256@openssh.com", b"nistp256", b"\x04" + b"\x02" * 64, b"ssh:")
    check(mod.parse_key(sk_ed) is not None, "an sk-ssh-ed25519 key parses")
    check(mod.parse_key(sk_ec) is not None, "an sk-ecdsa key parses")
    ed = key_line(b"ssh-ed25519", b"\x03" * 32)
    check(mod.parse_key(ed + " comment") is not None, "an ed25519 key with a comment parses")
    check(mod.parse_key(key_line(b"ssh-ed25519", b"\x03" * 32, b"extra")) is None,
          "a blob with trailing data is refused")
    check(mod.parse_key(key_line(b"ssh-rsa", b"\x03" * 32)) is None, "a blob whose type disagrees is refused")
    check(mod.parse_key(key_line(b"ssh-ed25519", b"\x03" * 31)) is None, "a short ed25519 key is refused")
    for cert in ("ssh-ed25519-cert-v01@openssh.com", "ssh-rsa-cert-v01@openssh.com",
                 "ecdsa-sha2-nistp256-cert-v01@openssh.com"):
        blob = wire(cert.encode(), b"\x00" * 32, b"\x03" * 32)
        check(mod.parse_key("%s %s" % (cert, base64.b64encode(blob).decode())) is None,
              "a %s certificate is refused as a key" % cert)
    check(mod.parse_key(key_line(b"ssh-dss", b"p", b"q", b"g", b"y")) is None,
          "an ssh-dss key is refused (OpenSSH 10 removed DSA)")

    # --- user.signingkey: git's literal rule, what cannot be checked --------
    check(mod._signingkey_source("key::" + ed, scratch) == ("literal", ed), "key:: is a literal")
    check(mod._signingkey_source(ed, scratch) == ("literal", ed), "a bare ssh- value is a literal")
    ec = "ecdsa-sha2-nistp256 AAAA"
    check(mod._signingkey_source(ec, scratch) == ("path", os.path.join(scratch, ec)),
          "a bare ecdsa- value is a path, as git reads it")
    spaced = " key::" + ed
    check(mod._signingkey_source(spaced, scratch) == ("path", os.path.join(scratch, spaced))
          and mod.resolve_signingkey(spaced, scratch) == (None, None)
          and not mod.signingkey_uncheckable(spaced, scratch),
          "a space-led ' key::' value is a missing path, as git reads it, never a literal")
    check(mod.signingkey_uncheckable("key::ssh-ed25519-cert-v01@openssh.com AAAA", scratch),
          "a certificate literal is not checked, never called a failure")
    private = os.path.join(scratch, "id_private")
    with open(private, "w") as fh:
        # A placeholder, not a key; the header is built in parts so the
        # secret scanners never see one in this file.
        word = "PRIVATE"
        fh.write(f"-----BEGIN OPENSSH {word} KEY-----\nx\n"
                 f"-----END OPENSSH {word} KEY-----\n")
    check(mod.resolve_signingkey(private, scratch) == (None, None) and mod.signingkey_uncheckable(private, scratch),
          "a private key path without its .pub is not checked")
    check(not mod.signingkey_uncheckable(os.path.join(scratch, "missing.pub"), scratch),
          "a missing path is not called uncheckable")

    # --- validity times: platform limits never raise ------------------------
    real_mktime = mod.time.mktime

    def overflow(tm):
        raise OverflowError("mktime argument out of range")

    mod.time.mktime = overflow
    try:
        check(mod.parse_ssh_time("20990101") is None, "an OverflowError from mktime() is a refusal")
    finally:
        mod.time.mktime = real_mktime
    check(mod.parse_ssh_time("99991231235959Z") is not None, "the largest four-digit UTC time parses")
    check(mod.parse_ssh_time("00000101Z") is None, "year 0 is refused")

    agent_out = "\n".join(["The agent has 1 identities.", "garbage", ed + " real", "", "\x1c"]) + "\n"
    bindir = os.path.join(scratch, "agent-bin")
    os.mkdir(bindir)
    stub(bindir, "ssh-add", 'printf "%%s" "%s"\n' % agent_out.replace('"', '\\"'))
    os.environ["PATH"] = bindir + os.pathsep + os.environ["PATH"]
    host = mod.Host(scratch, os.path.join(scratch, "config.local"), "INSTALLER")
    keys, err = host.agent()
    check(err is None and keys == {mod.parse_key(ed)}, "ssh-add noise lines are ignored")
    stub(bindir, "ssh-add", "sleep 5\n")
    mod.AGENT_TIMEOUT = 1
    keys, err = mod.Host(scratch, os.path.join(scratch, "c"), "I").agent()
    check(keys is None and "did not answer within 1 seconds" in (err or ""), "a hanging ssh-add times out")
    os.environ.clear()
    os.environ.update(saved)

    # --- values written into an ident line ------------------------------------
    for bad in ("me​@example.com", "me@example.com ", "me@exam\u0085ple.com",
                "me@[example].com", "me @example.com", "﻿me@example.com"):
        check(not mod.usable_principal(bad), "principal %r is refused" % bad)
    check(mod.usable_principal("zoë@example.com"), "a non-ASCII letter in a principal is accepted")
    check(not mod.usable_principal("a\udcffb@x.com"), "a principal holding a byte that is not UTF-8 is refused")
    for bad in ("Jane​Doe", "Jane Doe", "Jane\x7fDoe", "Jane <x>"):
        check(not mod.valid_name(bad), "name %r is refused" % bad)
    check(mod.valid_name('Zoë "Z" O\\Doe'), "a name with quotes and a backslash is accepted")

    # --- the full name the missing-name line suggests ------------------------
    class Pw(object):
        def __init__(self, login, gecos):
            self.pw_name, self.pw_gecos = login, gecos
    for login, gecos, want in (("jane", "Jane Doe", "Jane Doe"),
                               ("jane", "Jane Doe,Room 1,555,", "Jane Doe"),
                               ("jdoe", "& Doe", "Jdoe Doe"),
                               ("jdoe", "&,&", "Jdoe"),
                               ("jane", "", ""),
                               ("jane", "Jane ,Room 1", "Jane"),
                               ("jane", " Jane Doe ", "Jane Doe"),
                               ("jane", ",Room 1", ""),
                               ("jane", None, "")):
        got = mod.gecos_name(Pw(login, gecos))
        check(got == want, "gecos %r for %s reads as the full name %r (got %r)" % (gecos, login, want, got))
    check(mod.suggested_name("Jane Doe") == "Jane Doe", "the line suggests the account's full name when gecos has one")
    check(mod.suggested_name("") == "Full Name", "an account with no full name gets the placeholder")
    for bad in ("Jane\x1b[2JDoe", "Jane\u202eDoe", "Jane <x>", 'Jane "JJ" Doe', "Jane $(id)", "Jane `id`",
                "Jane\\Doe", "Jane!Doe"):
        got = mod.suggested_name(bad)
        check(got == "Full Name", "a full name %r that git, a shell or the terminal would not pass unchanged is not suggested (got %r)"
              % (bad, got))
    # A name _shown() would quote: pasted from the line, its single quotes
    # would become part of user.name.
    for edged in (" Jane", "Jane ", "Jane  Doe"):
        got = mod.suggested_name(edged)
        check(got == "Full Name", "a full name %r that would print quoted is not suggested (got %r)" % (edged, got))
    saved_account = mod.account_name
    mod.account_name = lambda: "Jane  Doe"
    try:
        line = mod.missing_name_line(mod.Host(scratch, os.path.join(scratch, "c"), "INSTALLER"))
    finally:
        mod.account_name = saved_account
    check(line == 'identity: user.name is not set - run: INSTALLER identity --name "Full Name"',
          "a full name with a run of spaces is never suggested inside quotes of its own (%r)" % line)
    saved_account = mod.account_name
    mod.account_name = lambda: "Jane\x1b[2JDoe"
    try:
        line = mod.missing_name_line(mod.Host(scratch, os.path.join(scratch, "c"), "INSTALLER"))
    finally:
        mod.account_name = saved_account
    check(line == 'identity: user.name is not set - run: INSTALLER identity --name "Full Name"'
          and mod._clean(line), "a control character in the account's full name never reaches the line")
    # A name a terminal shows as blank, or as a different name than the one
    # written: no letter or digit, a space other than U+0020, a Hangul
    # filler, another invisible code point _clean() lets through, or an
    # unassigned or private-use code point.
    for blank in ("\u3164", "Jane\u3164Doe", "\u115f", "\u1160", "Jane\uffa0Doe", "Jane\u00a0Doe",
                  "Jane\u3000Doe", "Jane\u2800Doe", "Jane\ufe0fDoe", "Jane\u034fDoe", "Jane\U000e0100Doe",
                  "Jane\U000e0002Doe", "Jane\ue000Doe", "Jane\U00016fe4Doe",
                  "\U00013441", "Jane\U00013442Doe", "-", "...", "&"):
        got = mod.suggested_name(blank)
        check(got == "Full Name", "a full name %r a terminal does not show as it is is not suggested (got %r)"
              % (blank, got))
    # A name longer than the cap would wrap the hint on a narrow terminal.
    at_cap = "J" * mod.SUGGESTED_NAME_MAX
    check(mod.suggested_name(at_cap) == at_cap and mod.suggested_name(at_cap + "J") == "Full Name",
          "a full name of %d characters is suggested, one more is not" % mod.SUGGESTED_NAME_MAX)
    for good in ("Jos\u00e9 \u00d1\u00fa\u00f1ez", "Jane Doe 3rd", "\u674e\u5c0f\u9f8d", "O'Brien-Smith"):
        got = mod.suggested_name(good)
        check(got == good, "a full name %r is suggested as it is (got %r)" % (good, got))
    # account_name(): an account the password database cannot name (KeyError)
    # or a failed lookup (OSError) has no full name, never a traceback.
    saved_getpwuid = mod.pwd.getpwuid
    for exc in (KeyError("getpwuid(): uid not found: 4242"), OSError(errno.EIO, "I/O error")):
        def raising(uid, exc=exc):
            raise exc
        mod.pwd.getpwuid = raising
        try:
            got = mod.account_name()
        finally:
            mod.pwd.getpwuid = saved_getpwuid
        check(got == "", "account_name() is empty when getpwuid() raises %s (got %r)" % (type(exc).__name__, got))

    # --- a configured host: signing_configured() and already_configured() ---
    class Fixed(mod.Host):
        """effective() answers from VALUES: rc 0 when the key is there, 1
        when it is not, the rc given for a (rc, err) tuple."""

        def __init__(self, values):
            mod.Host.__init__(self, scratch, os.path.join(scratch, "c"), "INSTALLER")
            self.values = values

        def effective(self, key, typ=None):
            v = self.values.get(key)
            if v is None:
                return mod.Value(1, "", "")
            if isinstance(v, tuple):
                return mod.Value(v[0], "", v[1])
            return mod.Value(0, v, "")

    signing = {"user.email": "me@example.com", "user.signingkey": "key::x", "commit.gpgsign": "true"}
    for values, want_signing, want_configured, what in (
            (dict(signing, **{"user.name": "Jane Doe"}), True, True, "every key and a name"),
            (signing, True, False, "every signing key but no name"),
            (dict(signing, **{"user.name": (128, "boom")}), True, False, "every signing key and an unreadable name"),
            ({"user.name": "Jane Doe", "user.email": "me@example.com"}, False, False, "a name but no signing key")):
        host = Fixed(values)
        got = (mod.signing_configured(host), mod.already_configured(host))
        check(got == (want_signing, want_configured),
              "%s: signing_configured, already_configured = %r, want %r" % (what, got, (want_signing, want_configured)))

    # run(): an unreadable user.name on a host that otherwise signs is not
    # "not set". It falls through to identity()'s path (stopped here at
    # global_reads_local()), never the missing-name line.
    reached = []
    patched = {"local_is_regular": lambda h: True, "git_isolate": lambda: None, "opted_out": lambda h: None,
               "global_reads_local": lambda h: reached.append(True) or False}
    saved_fns = dict((k, getattr(mod, k)) for k in patched)
    for k, f in patched.items():
        setattr(mod, k, f)
    mod._captured = []
    try:
        rc, _ = mod.run(Fixed(dict(signing, **{"user.name": (128, "fatal: boom")})), "auto", None, False)
        said = mod._captured
    finally:
        mod._captured = None
        for k, f in saved_fns.items():
            setattr(mod, k, f)
    check(rc == 1 and reached and not any("user.name is not set" in line for line in said),
          "auto with an unreadable user.name goes on to identity(), not the missing-name line (rc %d, %r)"
          % (rc, said))

    # --- files: the size cap; a KRL check with no usable TMPDIR -------------
    big = os.path.join(scratch, "big")
    with open(big, "wb") as fh:
        fh.write(b"#" * (mod.MAX_FILE + 1))
    data, why = mod.read_small_file(big)
    check(data is None and why == "larger than %d bytes" % mod.MAX_FILE, "a file over MAX_FILE is refused")
    with open(big, "wb") as fh:
        fh.write(b"#" * mod.MAX_FILE)
    data, why = mod.read_small_file(big)
    check(data is not None and len(data) == mod.MAX_FILE, "a file of exactly MAX_FILE is read")
    revoked = os.path.join(scratch, "revoked")
    with open(revoked, "w") as fh:
        fh.write("# list\n%s comment\0more\n" % ed)
    keys, err = mod.load_revocation(revoked)
    check(keys is None and "line 2 holds a NUL byte - writing nothing" in (err or ""),
          "a revocation line holding a NUL byte refuses, even after the key")
    real_tempdir = mod.tempfile.tempdir
    mod.tempfile.tempdir = os.path.join(scratch, "no-such-dir")
    try:
        check(mod.krl_revokes(big, mod.parse_key(ed)) is None, "an unwritable TMPDIR makes a KRL check unknown")
    finally:
        mod.tempfile.tempdir = real_tempdir

    # --- backup_once without hard links ---------------------------------------
    target = os.path.join(scratch, "config.local")
    with open(target, "w") as fh:
        fh.write("[user]\n\temail = a@x\n")
    real_link = mod.os.link

    def no_link(src, dst):
        raise OSError(errno.EPERM, "hard links not supported")

    mod.os.link = no_link
    fd = os.open(target, os.O_RDONLY)
    try:
        mod.backup_once(target, fd, 0o600)
        with open(target + ".bak") as fh:
            check(fh.read() == "[user]\n\temail = a@x\n", "backup_once falls back to O_EXCL when link fails")
        with open(target, "w") as fh:
            fh.write("changed\n")
        mod.backup_once(target, fd, 0o600)
        with open(target + ".bak") as fh:
            check("a@x" in fh.read(), "backup_once never replaces an existing .bak")
    finally:
        os.close(fd)
        mod.os.link = real_link
    check(not [n for n in os.listdir(scratch) if n.startswith(".config.local")], "no temp file is left behind")

    # --- a write the effective config does not read back --------------------
    home = os.path.join(scratch, "home")
    gitdir = os.path.join(home, ".config", "git")
    os.makedirs(gitdir)
    with open(os.path.join(gitdir, "config"), "w") as fh:
        fh.write("[gpg]\n\tformat = ssh\n[include]\n\tpath = config.local\n")
    signers = os.path.join(gitdir, "allowed_signers")
    with open(signers, "w") as fh:
        fh.write("me@example.com %s\n" % ed)
    os.environ.update({"HOME": home, "XDG_CONFIG_HOME": os.path.join(home, ".config"),
                       "GIT_CONFIG_SYSTEM": os.devnull})
    os.environ.pop("GIT_CONFIG_GLOBAL", None)

    class Shadowed(mod.Host):
        """A later level that wins over config.local once it exists."""

        def effective(self, key, typ=None):
            if key == "tag.gpgsign" and os.path.exists(self.config_local):
                return mod.Value(0, "false", "")
            return mod.Host.effective(self, key, typ)

    host = Shadowed(home, os.path.join(gitdir, "config.local"), "INSTALLER")
    host._agent = ({mod.parse_key(ed)}, None)
    mod._captured = []
    try:
        rc = mod.identity(host, None)
    finally:
        mod.git_release()
    said = mod._captured
    mod._captured = None
    check(rc == 1 and any("tag.gpgsign reads 'false'" in line for line in said),
          "a key the effective config does not read back is reported, exit 1")
    os.environ.clear()
    os.environ.update(saved)

    try:
        main_twice_units(mod, scratch)
    finally:
        mod.git_release()
        os.environ.clear()
        os.environ.update(saved)

    try:
        escaping_units(mod, scratch)
    finally:
        mod.git_release()
        os.environ.clear()
        os.environ.update(saved)

    try:
        command_word_units(mod, scratch)
    finally:
        mod.git_release()
        os.environ.clear()
        os.environ.update(saved)

    try:
        killed_units(mod, scratch)
    finally:
        os.environ.clear()
        os.environ.update(saved)

    print("%d failure(s)" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
