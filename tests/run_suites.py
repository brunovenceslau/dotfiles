# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""run_suites - the `make test` runner: every suite, several at a time.

Usage: python3 -I tests/run_suites.py SUITE...

The Makefile's `test` recipe unsets git's local env vars ($(GIT_ENV_SCRUB))
and then execs this file with $(TEST_FILES), so the scrub has happened before
any suite starts and a signal sent to the recipe reaches this process, not a
shell waiting on it. What it does, in order:

  - makes ONE scratch root, `mktemp -d` style (mode 0700, a fresh name, never
    a fixed one in a shared TMPDIR that another user could pre-create) under
    $TMPDIR (or /tmp when it is unset or empty), resolved to its absolute
    physical path,
    holding `real/` and a symlink `link -> real`. A relative link target, so a
    relative $TMPDIR cannot leave it dangling. Each suite gets its own
    directory `link/<n>` as TMPDIR: behind a symlink, as macOS's /var ->
    /private/var is, so a path assumption that only breaks there fails on
    Linux too, and private, so two suites running at once can never collide
    on a temp name. Any setup error fails closed before a suite runs;
  - runs every suite under `bash`, at most JOBS at a time, each in its own
    session (so its process group can be signalled as one), stdin from
    /dev/null (suites running at once cannot share a terminal), stdout and
    stderr into one log file per suite, outside every suite's TMPDIR;
  - prints each suite's log as one block when it ends, opened by
    `run <suite>` and closed by a `done <suite>:` line with its verdict, its
    wall time and its peak RSS, so the output of suites running at once never
    interleaves;
  - keeps going past a failure, prints every suite's time slowest first, and
    ends with `test: all N test files passed`, or with `test: FAILED:` naming
    every failed suite on stderr and exit 1;
  - on HUP, INT or TERM, signals every running suite's process group (TERM,
    then KILL after a grace period), removes the scratch root, and exits
    128+N (129, 130, 143), the codes a shell trap gives, which make reports
    as "Error N".

A suite that must not run alongside any other says so with a line that is
exactly SERIAL_MARK (below). Serial suites run first, one at a time, with
nothing else running; the rest then share the pool.

JOBS is $TEST_JOBS when it is set and non-empty (a positive integer, or the
run fails closed), otherwise min(CPUs, available memory / SUITE_MEMORY_MIB),
and at least 1. Python 3.9-safe: macOS's Command Line Tools ship 3.9.
"""

import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

# The memory one running suite is budgeted, in MiB. A suite is a process tree
# (bash, then zsh, git, python3, gawk, gitleaks or reuse under it), and the
# peak RSS each `done` line prints is the largest SINGLE process of that tree,
# never the sum. Measured on Linux (2026-10-12): the largest peak was 303 MiB
# (tests/check_patterns_test.sh), the next 130 MiB, most suites under 20 MiB,
# and all 60 suites at 10 at a time drew MemAvailable down by about 350 MiB in
# total. The budget sits above the largest single peak, so even a pool of only
# the heaviest suites fits. Raise it when a `done` line shows a peak near it.
SUITE_MEMORY_MIB = 384

# A suite holding this exact line runs alone. A comment, so bash ignores it.
SERIAL_MARK = "# run_suites: serial"

# How long a running suite gets to exit after TERM before it is KILLed.
GRACE_SECONDS = 5.0

# How often the scheduler looks for a finished suite or a pending signal.
POLL_SECONDS = 0.05

EXIT_ON_SIGNAL = {signal.SIGHUP: 129, signal.SIGINT: 130, signal.SIGTERM: 143}


def err(msg):
    print("ERROR: test: %s - failing closed" % msg, file=sys.stderr)
    return 1


def cpu_count():
    # The CPUs this process may run on (a container or taskset can narrow
    # them), where the platform can say; macOS has no affinity call.
    if hasattr(os, "sched_getaffinity"):
        try:
            return max(1, len(os.sched_getaffinity(0)))
        except OSError:
            pass
    return max(1, os.cpu_count() or 1)


def available_memory():
    """Bytes of memory a new process can take without swapping, or None.

    Linux: MemAvailable in /proc/meminfo, the kernel's own estimate. macOS:
    free + inactive + speculative pages from vm_stat (the pages the kernel
    hands out before it swaps), times the page size vm_stat reports. Never
    raises: an unknown answer is None and the caller says so.
    """
    try:
        with open("/proc/meminfo", encoding="ascii") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) * 1024
    except (OSError, ValueError, IndexError):
        pass
    try:
        out = subprocess.run(
            ["vm_stat"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=10, check=True,
            env=dict(os.environ, LC_ALL="C"),
        ).stdout.decode("ascii", "replace")
    except (OSError, subprocess.SubprocessError):
        return None
    return parse_vm_stat(out)


def parse_vm_stat(text):
    m = re.search(r"page size of (\d+) bytes", text)
    if not m:
        return None
    pages = 0
    for name in ("Pages free", "Pages inactive", "Pages speculative"):
        n = re.search(r"^%s:\s+(\d+)\.?$" % name, text, re.M)
        if not n:
            return None
        pages += int(n.group(1))
    return pages * int(m.group(1))


def pick_jobs(cpus, avail_bytes):
    """min(cpus, the suites the memory holds at SUITE_MEMORY_MIB each), >= 1.

    With no memory reading the CPU count alone decides.
    """
    jobs = cpus
    if avail_bytes is not None:
        jobs = min(jobs, avail_bytes // (SUITE_MEMORY_MIB * 1024 * 1024))
    return max(1, jobs)


def job_count():
    """(jobs, a line saying how they were chosen), or (None, an error)."""
    raw = os.environ.get("TEST_JOBS", "")
    if raw:
        if not re.fullmatch(r"[1-9][0-9]{0,3}", raw):
            return None, "TEST_JOBS must be a positive integer below 10000, got %r" % raw
        return int(raw), "TEST_JOBS=%s" % raw
    cpus, avail = cpu_count(), available_memory()
    if avail is None:
        how = "%d CPUs, available memory unknown" % cpus
    else:
        how = "%d CPUs, %d MiB available at %d MiB per suite" % (
            cpus, avail // (1024 * 1024), SUITE_MEMORY_MIB)
    return pick_jobs(cpus, avail), how


def is_serial(path):
    try:
        with open(path, "rb") as f:
            return any(line.rstrip(b"\r\n") == SERIAL_MARK.encode() for line in f)
    except OSError:
        # Unreadable here means unrunnable under bash too: run it in the pool
        # and let bash report the failure under the suite's own name.
        return False


def make_writable(path):
    """chmod u+rwx PATH and every directory under it, never through a link."""
    try:
        os.chmod(path, 0o700)
        entries = list(os.scandir(path))
    except OSError:
        return
    for entry in entries:
        if entry.is_dir(follow_symlinks=False):
            make_writable(entry.path)


def remove_tree(path):
    """rm -rf PATH; a suite may leave a directory it made read-only."""
    try:
        shutil.rmtree(path)
        return
    except FileNotFoundError:
        return
    except OSError:
        pass
    make_writable(path)
    try:
        shutil.rmtree(path)
    except OSError as e:
        print("WARN: test: could not remove the scratch root %s: %s" % (path, e),
              file=sys.stderr)


def peak_rss_mib(ru):
    # ru_maxrss is KiB on Linux and bytes on macOS.
    kib = ru.ru_maxrss // 1024 if sys.platform == "darwin" else ru.ru_maxrss
    return kib // 1024


class Run:
    """One suite: its process, its log and its timing."""

    def __init__(self, index, path, serial):
        self.index, self.path, self.serial = index, path, serial
        self.proc = None
        self.log = None
        self.start = 0.0
        self.seconds = 0.0
        self.code = None
        self.rss = 0


class Runner:
    def __init__(self, suites, jobs):
        self.jobs = jobs
        width = len(str(len(suites)))
        self.runs = [Run(str(i).zfill(width), p, is_serial(p))
                     for i, p in enumerate(suites, 1)]
        self.root = None
        self.signum = None
        self.running = []

    def on_signal(self, signum, _frame):
        # Only a flag: the scheduler acts on it between steps, so a signal can
        # never land between a fork and the bookkeeping of the child it made.
        if self.signum is None:
            self.signum = signum

    def setup(self):
        parent = os.environ.get("TMPDIR") or "/tmp"
        try:
            self.root = tempfile.mkdtemp(prefix="make-test-tmp.", dir=parent)
        except OSError as e:
            return err("could not make the scratch root under %s (%s)" % (parent, e))
        try:
            # Absolute and physical, so TMPDIR stays valid wherever a suite
            # changes directory; realpath never needs CDPATH, unlike `cd -P`.
            self.root = os.path.realpath(self.root)
            os.mkdir(os.path.join(self.root, "real"))
            os.symlink("real", os.path.join(self.root, "link"))
            os.mkdir(os.path.join(self.root, "logs"))
            for run in self.runs:
                os.mkdir(self.tmpdir(run))
        except OSError as e:
            return err("could not lay out the scratch root %s (%s)" % (self.root, e))
        return 0

    def tmpdir(self, run):
        return os.path.join(self.root, "link", run.index)

    def launch(self, run):
        env = dict(os.environ, TMPDIR=self.tmpdir(run))
        run.log = open(os.path.join(self.root, "logs", run.index + ".log"), "wb")
        run.start = time.monotonic()
        run.proc = subprocess.Popen(
            ["bash", run.path], stdin=subprocess.DEVNULL, stdout=run.log,
            stderr=subprocess.STDOUT, env=env, start_new_session=True,
        )
        self.running.append(run)

    def reap(self):
        """Collect every suite that has ended; returns them in end order."""
        done = []
        for run in list(self.running):
            # wait4, not Popen.poll: its rusage is the peak RSS the `done`
            # line prints. returncode is set by hand so Popen never waits again.
            try:
                pid, status, ru = os.wait4(run.proc.pid, os.WNOHANG)
            except ChildProcessError:
                pid, status, ru = run.proc.pid, 255 << 8, None
            if pid == 0:
                continue
            run.proc.returncode = run.code = os.waitstatus_to_exitcode(status)
            run.seconds = time.monotonic() - run.start
            run.rss = peak_rss_mib(ru) if ru is not None else 0
            run.log.close()
            self.running.remove(run)
            done.append(run)
        return done

    def report(self, run):
        out = sys.stdout.buffer
        out.write(("run %s\n" % run.path).encode())
        with open(run.log.name, "rb") as f:
            body = f.read()
        out.write(body)
        if body and not body.endswith(b"\n"):
            out.write(b"\n")
        if run.code == 0:
            verdict = "ok"
        elif run.code < 0:
            verdict = "FAILED (killed by signal %d)" % -run.code
        else:
            verdict = "FAILED (exit %d)" % run.code
        out.write(("done %s: %s in %.1fs, peak RSS %d MiB\n"
                   % (run.path, verdict, run.seconds, run.rss)).encode())
        out.flush()

    def stop_all(self):
        """TERM every running suite's group, then KILL what is left."""
        for run in self.running:
            try:
                os.killpg(run.proc.pid, signal.SIGTERM)
            except OSError:
                pass
        deadline = time.monotonic() + GRACE_SECONDS
        while self.running and time.monotonic() < deadline:
            self.reap()
            time.sleep(POLL_SECONDS)
        for run in self.running:
            try:
                os.killpg(run.proc.pid, signal.SIGKILL)
            except OSError:
                pass
            run.proc.wait()
            run.log.close()
        self.running = []

    def schedule(self):
        """Run every suite; returns the exit code."""
        started = time.monotonic()
        # Serial suites first: they need an empty pool, which costs nothing
        # before the pool has started and a drain of it anywhere later.
        pending = [r for r in self.runs if r.serial] + [r for r in self.runs if not r.serial]
        while pending or self.running:
            if self.signum is not None:
                return self.interrupted()
            for run in self.reap():
                self.report(run)
            while pending and self.signum is None:
                nxt = pending[0]
                serial_busy = any(r.serial for r in self.running)
                if serial_busy or len(self.running) >= self.jobs:
                    break
                if nxt.serial and self.running:
                    break
                pending.pop(0)
                try:
                    self.launch(nxt)
                except OSError as e:
                    err("could not start %s (%s)" % (nxt.path, e))
                    self.stop_all()
                    return 1
            time.sleep(POLL_SECONDS)
        if self.signum is not None:
            return self.interrupted()
        return self.summary(time.monotonic() - started)

    def interrupted(self):
        self.stop_all()
        name = signal.Signals(self.signum).name
        print("test: interrupted by %s, every running suite stopped" % name,
              file=sys.stderr)
        return EXIT_ON_SIGNAL[self.signum]

    def summary(self, wall):
        print("test: suite times, slowest first:")
        for run in sorted(self.runs, key=lambda r: r.seconds, reverse=True):
            print("  %7.1fs  %s" % (run.seconds, run.path))
        print("test: wall time %.1fs, %d at a time" % (wall, self.jobs))
        failed = [r.path for r in self.runs if r.code != 0]
        sys.stdout.flush()
        if failed:
            print("test: FAILED: %s" % " ".join(failed), file=sys.stderr)
            return 1
        print("test: all %d test files passed" % len(self.runs))
        return 0


def main(argv):
    if not argv:
        print("test: no tests found")
        return 0
    jobs, how = job_count()
    if jobs is None:
        return err(how)
    runner = Runner(argv, jobs)
    for sig in EXIT_ON_SIGNAL:
        signal.signal(sig, runner.on_signal)
    try:
        rc = runner.setup()
        if rc == 0:
            serial = sum(1 for r in runner.runs if r.serial)
            print("test: %d suites (%d serial), %d at a time (%s)"
                  % (len(runner.runs), serial, jobs, how))
            sys.stdout.flush()
            rc = runner.schedule()
        return rc
    finally:
        # Runs on every path, a failed setup and a signal included. A second
        # signal during cleanup only sets the flag again, so it cannot cut
        # the removal short.
        runner.stop_all()
        if runner.root is not None:
            remove_tree(runner.root)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
