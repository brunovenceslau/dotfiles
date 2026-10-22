# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# lib/host_maxfiles.py - raise the macOS open-file limit at boot with one
# root-owned LaunchDaemon, check it, or remove it.
#
# Called by install.sh's `maxfiles` arm as
# `python3 -I lib/host_maxfiles.py --mode install|uninstall|status`, and by
# tests/host_maxfiles_test.sh as `--mode render --out DIR`, which writes the
# plist into DIR and needs no privilege on any platform.
#
# MAXFILES below is the one place the value lives: the plist is generated from
# it, and the checks compare against it. Change it there and run
# `install.sh maxfiles` again: the plist is replaced and the daemon reloaded.
#
# The daemon runs ONE command line: sysctl first, then `launchctl limit`,
# because `launchctl limit` does not go above kern.maxfilesperproc, and two
# daemons have no guaranteed order. /etc/sysctl.conf is not used: it did not
# apply reliably on the macOS host where this was measured (2026-10-22).
#
# Privilege: this process is never root (install.sh refuses root). Each step
# that needs root runs as its own `/usr/bin/sudo` command, printed before it
# runs, so the operator sees every privileged command and sudo asks for the
# password itself. Every program is named by its absolute path, so a tool on
# the user's PATH cannot answer for it. The plist is generated and checked
# with `plutil -lint` before sudo is asked for anything, and installed
# root:wheel 0644 with `install -S` (a new file renamed into place), so no user
# process can change what root runs at boot. It is read back: the daemon is
# loaded only when the installed bytes are the checked ones, and an installed
# file that is not is removed again, since launchd would load it at the next
# boot. A plist at that path that this module did not generate (another
# recipe with the same Label) is neither replaced nor removed: the operator
# moves it away first.
#
# Idempotent: a host whose installed plist is the generated one, owned
# root:wheel 0644, and whose kernel and launchd already hold MAXFILES gets no
# sudo command at all. Any other state gets the steps it lacks. A booted-out
# daemon leaves its values in place until the next boot; uninstall says so.
#
# Python, not bash: plistlib writes and reads the plist, which bash cannot
# do safely; not Go, because a fresh Mac has no Go toolchain while python3
# ships with the Command Line Tools. Standard library only, Python 3.9 safe.
#
# Exit status: 0 done or nothing to do (any platform but macOS included);
# 1 a step failed, or `status` found the limit not in place; 2 a usage error.

import argparse
import os
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time

# The open-file limit, for kern.maxfiles, kern.maxfilesperproc and both the
# soft and hard `launchctl limit maxfiles`. Measured on a macOS host on
# 2026-10-22. Scope: every Mac of the maintainer that uses this framework.
MAXFILES = 524288

LABEL = "local.limits.maxfiles"
PLIST_PATH = "/Library/LaunchDaemons/%s.plist" % LABEL

SUDO = "/usr/bin/sudo"
SYSCTL = "/usr/sbin/sysctl"
LAUNCHCTL = "/bin/launchctl"
PLUTIL = "/usr/bin/plutil"
INSTALL = "/usr/bin/install"
RM = "/bin/rm"

PREFIX = "maxfiles: "


def say(msg):
    print(PREFIX + msg, flush=True)


def warn(msg):
    print(PREFIX + msg, file=sys.stderr, flush=True)


def render(value=MAXFILES):
    """The plist bytes for VALUE. The command line is built from an int, so
    nothing but digits reaches the shell."""
    value = int(value)
    if value <= 0:
        raise ValueError("MAXFILES must be a positive integer")
    cmd = "%s -w kern.maxfiles=%d kern.maxfilesperproc=%d && %s limit maxfiles %d %d" % (
        SYSCTL, value, value, LAUNCHCTL, value, value)
    return plistlib.dumps({
        "Label": LABEL,
        "ProgramArguments": ["/bin/sh", "-c", cmd],
        "RunAtLoad": True,
    }, fmt=plistlib.FMT_XML, sort_keys=True)


def run(argv):
    """Run ARGV with the terminal attached (sudo prompts on it); returns the
    exit status. The tests replace this function."""
    try:
        return subprocess.run(argv).returncode
    except OSError as e:
        warn("could not run %s: %s" % (argv[0], e.strerror or e))
        return 127


def capture(argv):
    """ARGV's stdout, or None when it cannot run or fails."""
    try:
        p = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, universal_newlines=True)
    except OSError:
        return None
    return p.stdout if p.returncode == 0 else None


def _int(word):
    try:
        return int(word)
    except (TypeError, ValueError):
        return None


def ours(data):
    """True when DATA is a plist this module generated, for any value."""
    try:
        pl = plistlib.loads(data)
        n = re.search(r"kern\.maxfiles=([0-9]+) ", pl["ProgramArguments"][2])
        return n is not None and pl == plistlib.loads(render(int(n.group(1))))
    except Exception:
        return False


def read_state():
    """What is in place now, read without privilege. The tests replace this
    function. Keys: installed (bytes or None), owner_ok, maxfiles, perproc,
    soft, hard (an int, or None when it could not be read as one), and shown,
    the words as printed, for messages."""
    state = {"installed": None, "owner_ok": False, "shown": {}}
    try:
        with open(PLIST_PATH, "rb") as f:
            # fstat, not stat: the owner and the bytes come from one file.
            st = os.fstat(f.fileno())
            state["installed"] = f.read()
        state["owner_ok"] = (stat.S_ISREG(st.st_mode) and st.st_nlink == 1
                             and st.st_uid == 0 and st.st_gid == 0
                             and (st.st_mode & 0o7777) == 0o644)
    except FileNotFoundError:
        pass
    except OSError as e:
        warn("cannot read %s: %s" % (PLIST_PATH, e.strerror or e))
        state["installed"] = b""
    out = capture([SYSCTL, "-n", "kern.maxfiles", "kern.maxfilesperproc"])
    words = out.split() if out is not None else []
    ok = len(words) == 2
    for i, k in enumerate(("maxfiles", "perproc")):
        state[k] = _int(words[i]) if ok else None
        state["shown"][k] = words[i] if ok else "unreadable"
    # `launchctl limit maxfiles` prints `maxfiles <soft> <hard>`; a limit can
    # read `unlimited`, which is not the value, and is shown as printed.
    out = capture([LAUNCHCTL, "limit", "maxfiles"])
    words = out.split() if out is not None else []
    ok = len(words) == 3 and words[0] == "maxfiles"
    for i, k in enumerate(("soft", "hard"), 1):
        state[k] = _int(words[i]) if ok else None
        state["shown"][k] = words[i] if ok else "unreadable"
    return state


def applied(state, value=MAXFILES):
    return all(state.get(k) == value for k in ("maxfiles", "perproc", "soft", "hard"))


def file_ok(state, desired):
    return state["installed"] == desired and state["owner_ok"]


def foreign(state):
    return state["installed"] is not None and not ours(state["installed"])


def describe(state):
    shown = state.get("shown", {})
    def show(k):
        return shown.get(k) or ("unreadable" if state.get(k) is None else str(state[k]))
    return "kern.maxfiles %s, kern.maxfilesperproc %s, launchctl maxfiles %s %s" % (
        show("maxfiles"), show("perproc"), show("soft"), show("hard"))


REMOVE = ([SUDO, RM, "-f", PLIST_PATH], False)


def plan_install(state, desired, staged):
    """The (argv, may_fail) steps that bring STATE to DESIRED, for a host
    do_install found short of it; STAGED is the checked plist to copy. The
    bootout may fail: it only clears a loaded copy so the bootstrap loads the
    new one."""
    steps = []
    if not file_ok(state, desired):
        steps.append(([SUDO, INSTALL, "-S", "-o", "root", "-g", "wheel", "-m", "644",
                       staged, PLIST_PATH], False))
    steps.append(([SUDO, LAUNCHCTL, "bootout", "system/" + LABEL], True))
    steps.append(([SUDO, LAUNCHCTL, "bootstrap", "system", PLIST_PATH], False))
    return steps


def plan_uninstall(state):
    if state["installed"] is None:
        return []
    return [([SUDO, LAUNCHCTL, "bootout", "system/" + LABEL], True), REMOVE]


def execute(steps, before_load=None):
    """Run each step, printed first. BEFORE_LOAD, when given, runs right
    before the bootstrap; when it returns False the run stops there."""
    for argv, may_fail in steps:
        if before_load is not None and argv[2:4] == ["bootstrap", "system"]:
            if not before_load():
                return False
        say("running: " + shlex.join(argv))
        rc = run(argv)
        if rc != 0 and not may_fail:
            warn("failed (exit %d): %s" % (rc, shlex.join(argv)))
            return False
    return True


def settled(tries=50, pause=0.1):
    """The state once the daemon's RunAtLoad command has run: launchd starts
    it after bootstrap returns, so the values are polled for up to 5s."""
    state = read_state()
    for _ in range(tries - 1):
        if applied(state):
            break
        time.sleep(pause)
        state = read_state()
    return state


def refuse_foreign(what):
    warn("%s holds a plist this step did not generate; not %s it."
         " Move it away first if it is yours to replace" % (PLIST_PATH, what))
    return 1


def do_install():
    desired = render()
    state = read_state()
    if file_ok(state, desired) and applied(state):
        say("in place, nothing to do (%s)" % describe(state))
        return 0
    if foreign(state):
        return refuse_foreign("replacing")
    tmp = tempfile.mkdtemp(prefix="maxfiles.")
    staged = os.path.join(tmp, LABEL + ".plist")
    try:
        with open(staged, "wb") as f:
            f.write(desired)
        if run([PLUTIL, "-lint", staged]) != 0:
            warn("plutil -lint rejected the generated plist; nothing was installed")
            return 1
        say("this writes %s (root:wheel 0644) and loads it with launchctl;"
            " sudo may ask for your password" % PLIST_PATH)
        mismatch = []

        def readback():
            if not file_ok(read_state(), desired):
                mismatch.append(True)
                return False
            return True
        if not execute(plan_install(state, desired, staged), readback):
            if mismatch:
                warn("%s is not the checked plist owned root:wheel 0644;"
                     " not loading it, and removing it so no boot loads it" % PLIST_PATH)
                execute([REMOVE])
            return 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    after = settled()
    if not applied(after):
        warn("loaded, but the limit is not in place: %s" % describe(after))
        return 1
    say("in place: %s" % describe(after))
    say("quit and reopen running apps (the terminal, Docker or sbx) so they inherit it")
    return 0


def do_uninstall():
    state = read_state()
    steps = plan_uninstall(state)
    if not steps:
        say("%s is not installed, nothing to do" % PLIST_PATH)
        return 0
    if foreign(state):
        return refuse_foreign("removing")
    say("this unloads and removes %s; sudo may ask for your password" % PLIST_PATH)
    if not execute(steps):
        return 1
    say("removed. The current limits stay until the next boot (%s)" % describe(read_state()))
    return 0


def do_status():
    state = read_state()
    desired = render()
    if state["installed"] is None:
        file_line = "not installed"
    elif file_ok(state, desired):
        file_line = "installed, current"
    elif state["installed"] == desired:
        file_line = "installed, but not a single root:wheel 0644 file"
    elif foreign(state):
        file_line = "holds a plist this step did not generate"
    else:
        file_line = "installed, with another value (run install.sh maxfiles)"
    say("%s: %s" % (PLIST_PATH, file_line))
    say("want %d; have %s" % (MAXFILES, describe(state)))
    return 0 if file_ok(state, desired) and applied(state) else 1


def main(argv, platform=None):
    ap = argparse.ArgumentParser(prog="install.sh maxfiles", add_help=False)
    ap.add_argument("--mode", choices=("install", "uninstall", "status", "render"), required=True)
    ap.add_argument("--out")
    try:
        args = ap.parse_args(argv)
    except SystemExit:
        return 2
    if (args.out is not None) != (args.mode == "render"):
        warn("--out is taken by --mode render, and only by it")
        return 2
    if args.mode == "render":
        path = os.path.join(args.out, LABEL + ".plist")
        with open(path, "wb") as f:
            f.write(render())
        print(path)
        return 0
    platform = sys.platform if platform is None else platform
    if platform != "darwin":
        say("macOS only (this host is %s): nothing to do" % platform)
        return 0
    return {"install": do_install, "uninstall": do_uninstall, "status": do_status}[args.mode]()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
