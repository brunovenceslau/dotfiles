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
import signal
import stat
import struct
import subprocess
import sys

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
    mod = load(module)

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

    print("%d failure(s)" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
