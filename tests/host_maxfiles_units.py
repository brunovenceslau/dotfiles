# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# tests/host_maxfiles_units.py - the decisions of lib/host_maxfiles.py, with
# its two edges replaced: run() (every command it would execute) and
# read_state() (what it reads from the host). Nothing here runs sudo,
# launchctl or sysctl, on any platform. Run by tests/host_maxfiles_test.sh as
# `python3 -I -B tests/host_maxfiles_units.py <module path>`; prints one
# `ok NAME` or `BAD NAME: why` per case.

import importlib.util
import io
import sys
import contextlib

spec = importlib.util.spec_from_file_location("host_maxfiles", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.time.sleep = lambda s: None       # settled() polls; the stub state is final

N = m.MAXFILES
DESIRED = m.render()


def check(name, cond, why):
    print(("ok %s" % name) if cond else ("BAD %s: %s" % (name, why)))


def host(installed=None, owner_ok=False, values=None):
    v = values if values is not None else (None, None, None, None)
    return {"installed": installed, "owner_ok": owner_ok,
            "maxfiles": v[0], "perproc": v[1], "soft": v[2], "hard": v[3]}


class Fake:
    """A host whose state changes as the planned commands run on it."""
    def __init__(self, state, fail=()):
        self.state, self.fail, self.ran = dict(state), set(fail), []

    def run(self, argv):
        self.ran.append(argv)
        verb = argv[1] if argv[0] == m.SUDO else argv[0]
        if verb in self.fail or (len(argv) > 2 and argv[2] in self.fail):
            return 1
        if argv[0] == m.PLUTIL:
            return 0
        if verb == m.INSTALL:
            with open(argv[-2], "rb") as f:
                self.state["installed"] = f.read()
            self.state["owner_ok"] = True
        elif argv[2:4] == ["bootstrap", "system"]:
            if self.state["installed"] == DESIRED:
                for k in ("maxfiles", "perproc", "soft", "hard"):
                    self.state[k] = N
        elif verb == m.RM:
            self.state["installed"], self.state["owner_ok"] = None, False
        return 0

    def read(self):
        return dict(self.state)

    def sudo(self):
        return [a for a in self.ran if a[0] == m.SUDO]


def drive(fake, argv, platform="darwin"):
    m.run, m.read_state = fake.run, fake.read
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = m.main(argv, platform=platform)
    return rc, out.getvalue(), err.getvalue()


def verbs(argvs):
    return [a[2] if a[1] == m.LAUNCHCTL else a[1] for a in argvs]


# The plist: one command, sysctl before launchctl limit, the value from MAXFILES.
pl = m.plistlib.loads(DESIRED)
cmd = pl["ProgramArguments"][2]
check("plist keys", sorted(pl) == ["Label", "ProgramArguments", "RunAtLoad"], sorted(pl))
check("plist label", pl["Label"] == m.LABEL and m.PLIST_PATH.endswith("/" + m.LABEL + ".plist"), pl["Label"])
check("plist one command", pl["ProgramArguments"][:2] == ["/bin/sh", "-c"] and pl["RunAtLoad"] is True, pl)
check("plist sysctl first", cmd.index(m.SYSCTL) < cmd.index(" && ") < cmd.index(m.LAUNCHCTL + " limit"), cmd)
check("plist value", cmd.count(str(N)) == 4 and "kern.maxfiles=%d " % N in cmd
      and "kern.maxfilesperproc=%d " % N in cmd and cmd.endswith("maxfiles %d %d" % (N, N)), cmd)
check("plist other value", "=1234 " in m.plistlib.loads(m.render(1234))["ProgramArguments"][2], "render(1234)")
try:
    m.render(0)
    check("plist refuses 0", False, "render(0) returned")
except ValueError:
    check("plist refuses 0", True, "")

# A fresh host: lint, then install, bootout, bootstrap, each through sudo.
f = Fake(host(values=(122880, 61440, 256, None)))
rc, out, err = drive(f, ["--mode", "install"])
check("fresh rc", rc == 0, (rc, out, err))
check("fresh lint before sudo", f.ran[0][:2] == [m.PLUTIL, "-lint"], f.ran)
check("fresh steps", verbs(f.sudo()) == [m.INSTALL, "bootout", "bootstrap"], f.sudo())
inst = f.sudo()[0]
check("fresh owner and mode", inst[2:9] == ["-S", "-o", "root", "-g", "wheel", "-m", "644"] and inst[-1] == m.PLIST_PATH, inst)
check("fresh commands shown", all(("running: " + " ".join(a)) in out for a in f.sudo()), out)
check("fresh restart note", "reopen" in out, out)

# Again: nothing to do, no sudo, no lint.
f2 = Fake(f.state)
rc, out, err = drive(f2, ["--mode", "install"])
check("rerun rc", rc == 0, (rc, err))
check("rerun no command", f2.ran == [], f2.ran)
check("rerun says so", "nothing to do" in out, out)

# A different value installed: replaced and reloaded.
f3 = Fake(host(m.render(65536), True, (65536,) * 4))
rc, out, err = drive(f3, ["--mode", "install"])
check("new value rc", rc == 0 and f3.state["installed"] == DESIRED, (rc, err))
check("new value steps", verbs(f3.sudo()) == [m.INSTALL, "bootout", "bootstrap"], f3.sudo())

# The right file, but the daemon booted out (values back to the defaults): reload only.
f4 = Fake(host(DESIRED, True, (122880, 61440, 256, None)))
rc, out, err = drive(f4, ["--mode", "install"])
check("reload only", rc == 0 and verbs(f4.sudo()) == ["bootout", "bootstrap"], f4.sudo())

# The right bytes with the wrong owner: reinstalled.
f5 = Fake(host(DESIRED, False, (N,) * 4))
rc, out, err = drive(f5, ["--mode", "install"])
check("wrong owner reinstalled", rc == 0 and verbs(f5.sudo())[0] == m.INSTALL, f5.sudo())

# plutil rejects the plist: no sudo at all.
f6 = Fake(host(), fail={m.PLUTIL})
rc, out, err = drive(f6, ["--mode", "install"])
check("lint fail rc", rc == 1 and f6.sudo() == [], (rc, f6.sudo()))

# The installed file is not what was checked: no bootstrap.
class Swapped(Fake):
    def run(self, argv):
        rc = Fake.run(self, argv)
        if argv[0] == m.SUDO and argv[1] == m.INSTALL:
            self.state["installed"] = b"other"
        return rc
f7 = Swapped(host())
rc, out, err = drive(f7, ["--mode", "install"])
check("readback stops the load", rc == 1 and "bootstrap" not in verbs(f7.sudo()), (rc, f7.sudo(), err))
check("readback removes the file", verbs(f7.sudo()) == [m.INSTALL, "bootout", m.RM]
      and f7.state["installed"] is None and "removing it" in err, (f7.sudo(), err))

# A failed install step stops the run; a failed bootout does not.
f8 = Fake(host(), fail={m.INSTALL})
rc, out, err = drive(f8, ["--mode", "install"])
check("install fail stops", rc == 1 and verbs(f8.sudo()) == [m.INSTALL], f8.sudo())
f9 = Fake(host(), fail={"bootout"})
rc, out, err = drive(f9, ["--mode", "install"])
check("bootout fail tolerated", rc == 0 and verbs(f9.sudo()) == [m.INSTALL, "bootout", "bootstrap"], (rc, err))

# Loaded but the values never arrive: a failure that names them.
class Inert(Fake):
    def run(self, argv):
        if argv[2:4] == ["bootstrap", "system"]:
            self.ran.append(argv)
            return 0
        return Fake.run(self, argv)
f10 = Inert(host())
rc, out, err = drive(f10, ["--mode", "install"])
check("not applied rc", rc == 1 and "not in place" in err, (rc, err))

# Values that arrive a few polls after the bootstrap, as RunAtLoad's do.
class Late(Fake):
    def __init__(self, state):
        Fake.__init__(self, state)
        self.reads = None
    def run(self, argv):
        if argv[2:4] == ["bootstrap", "system"]:
            self.ran.append(argv)
            self.reads = 0
            return 0
        return Fake.run(self, argv)
    def read(self):
        if self.reads is not None:
            self.reads += 1
            if self.reads == 4:
                for k in ("maxfiles", "perproc", "soft", "hard"):
                    self.state[k] = N
        return dict(self.state)
f15 = Late(host())
rc, out, err = drive(f15, ["--mode", "install"])
check("late values polled", rc == 0 and f15.reads >= 4, (rc, f15.reads, err))

# A plist at the path that this step did not generate: neither replaced nor removed.
for mode in ("install", "uninstall"):
    f16 = Fake(host(b"<plist>someone else's</plist>", True, (256,) * 4))
    rc, out, err = drive(f16, ["--mode", mode])
    check("foreign %s refused" % mode, rc == 1 and f16.ran == [] and "did not generate" in err, (rc, f16.ran, err))

# Uninstall: bootout then rm; again, nothing to do.
f11 = Fake(dict(f.state))
rc, out, err = drive(f11, ["--mode", "uninstall"])
check("uninstall steps", rc == 0 and verbs(f11.sudo()) == ["bootout", m.RM], f11.sudo())
check("uninstall next boot", "next boot" in out, out)
f12 = Fake(f11.state)
rc, out, err = drive(f12, ["--mode", "uninstall"])
check("uninstall again", rc == 0 and f12.ran == [] and "nothing to do" in out, (rc, f12.ran, out))

f17 = Fake(dict(f.state), fail={m.RM})
rc, out, err = drive(f17, ["--mode", "uninstall"])
check("uninstall rm fail", rc == 1 and verbs(f17.sudo()) == ["bootout", m.RM], (rc, f17.sudo()))
f18 = Fake(dict(f.state), fail={"bootout"})
rc, out, err = drive(f18, ["--mode", "uninstall"])
check("uninstall bootout fail tolerated", rc == 0 and f18.state["installed"] is None, (rc, err))

# Status: read only, 0 only when everything is in place.
rc, out, err = drive(Fake(f.state), ["--mode", "status"])
check("status in place", rc == 0 and "current" in out, (rc, out))
f13 = Fake(host())
rc, out, err = drive(f13, ["--mode", "status"])
check("status missing", rc == 1 and f13.ran == [] and "not installed" in out, (rc, out))

# Any other platform: nothing runs, and it says why.
for mode in ("install", "uninstall", "status"):
    f14 = Fake(host())
    rc, out, err = drive(f14, ["--mode", mode], platform="linux")
    check("linux %s" % mode, rc == 0 and f14.ran == [] and "macOS only" in out, (rc, out))

# Usage errors.
rc, out, err = drive(Fake(host()), ["--mode", "install", "--out", "/tmp"])
check("out only with render", rc == 2, rc)
rc, out, err = drive(Fake(host()), ["--mode", "render"])
check("render needs out", rc == 2, rc)
for name, st, want in (
        ("status wrong owner", host(DESIRED, False, (N,) * 4), "not a single root:wheel 0644 file"),
        ("status other value", host(m.render(65536), True, (65536,) * 4), "with another value"),
        ("status foreign", host(b"x", True, (N,) * 4), "did not generate")):
    f19 = Fake(st)
    rc, out, err = drive(f19, ["--mode", "status"])
    check(name, rc == 1 and f19.ran == [] and want in out, (rc, out))

# A limit launchctl prints as `unlimited` is shown as printed, not "unreadable".
st = host(values=(N, N, N, None))
st["shown"] = {"maxfiles": str(N), "perproc": str(N), "soft": str(N), "hard": "unlimited"}
check("describe unlimited", m.describe(st).endswith("maxfiles %d unlimited" % N), m.describe(st))
check("ours any value", m.ours(m.render(65536)) and not m.ours(b"x")
      and not m.ours(m.render(65536).replace(b"RunAtLoad", b"KeepAlive")), "ours()")
