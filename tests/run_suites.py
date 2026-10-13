# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""run_suites - the `make test` runner: every suite, several at a time.

Usage: python3 -I tests/run_suites.py SUITE...

The Makefile's `test` recipe unsets git's local env vars ($(GIT_ENV_SCRUB))
and then execs this file with $(TEST_FILES), so the scrub has happened before
any suite starts and a signal sent to the recipe reaches this process, not a
shell waiting on it. What it does, in order:

  - makes ONE scratch root under $TMPDIR (or /tmp when it is unset or empty),
    `mktemp -d` style: mode 0700 and a fresh name, never a fixed one in a
    shared TMPDIR that another user could pre-create. The root is resolved to
    its absolute physical path and holds `real/` and a symlink `link -> real`,
    whose target is relative, so a relative $TMPDIR cannot leave it dangling.
    Each suite gets its own directory `link/<n>` as TMPDIR: behind a symlink,
    as macOS's /var -> /private/var is, so a path assumption that only breaks
    there fails on Linux too, and private, so two suites running at once can
    never collide on a temp name. Any setup error fails closed before a suite
    runs;
  - runs every suite as `bash -- <suite>`, at most JOBS at a time, each in a
    session of its own (so its process group can be signalled as one), stdin
    from /dev/null (suites running at once cannot share a terminal), stdout
    and stderr into one log file per suite, outside every suite's TMPDIR,
    always a new file: a name already there (a symlink an earlier suite
    planted, say) is never written through, and the run stops as for a
    suite that could not start. A `start <suite>` line says when each one
    starts, so a suite that hangs until a CI timeout can still be named;
  - prints each suite's log as one block when it ends, opened by
    `run <suite>` and closed by a `done <suite>:` line with its verdict, its
    wall time and a peak RSS, so the output of suites running at once never
    interleaves. When a suite's main process ends, whatever it left running
    in its process group is killed;
  - keeps going past a failure, prints every suite's time slowest first, and
    ends with `test: all N test files passed`, or with `test: FAILED:` naming
    every failed suite on stderr and exit 1;
  - on HUP, INT, QUIT or TERM, reports the suites that had already ended, then
    signals every running suite's process group with TERM and waits until
    the group is empty or the grace period is over, when what is left gets
    KILL (a second signal skips the rest of the grace period). Each stopped
    suite's block is printed with an INTERRUPTED verdict and the time until
    its main process was reaped, so a suite that ignored TERM counts the
    grace period too. The scratch root is removed, and the exit is 128+N
    (129, 130, 131, 143), the codes a shell trap gives, which make reports
    as "Error N". A process that left its suite's group (setsid, set -m, a
    daemon) is out of reach, and so is everything after a KILL of the
    runner itself, which no process can catch: its suites keep running in
    their sessions and the scratch root stays;
  - when its stdout is closed (its reader, such as `head`, went away),
    stops every running suite, removes the scratch root and says so on
    stderr (unless stderr went to the same reader), exit 1.

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
# peak RSS each `done` line prints is that of the largest single process
# among the suite's main process and the descendants it waited for, never a
# sum. Measured on Linux (2026-10-12): the largest peak was 303 MiB
# (tests/check_patterns_test.sh), the next 130 MiB, most suites under 20 MiB,
# and all 60 suites at 10 at a time drew MemAvailable down by about 350 MiB in
# total. On Linux the budget sits above the largest single peak, so even a
# pool of only the heaviest suites fits there. Not on every host: on the macOS
# arm64 CI leg (2026-10-13) tests/linkcheck_test.sh peaked at 1271 MiB, from a
# regex backtracking stack on its hostile input. A peak above the budget is
# fixed in the suite that has it, not by raising the budget, which would
# lower the job count of every run on every host for one suite. That case,
# its remedy (the pending item linkcheck-tag-scanner) and what reopens it are
# in the docs/development.md Deferred decisions row "Tell an out-of-memory
# kill apart from an expected failure in `make test`".
SUITE_MEMORY_MIB = 384

# A suite holding this exact line runs alone. A comment, so bash ignores it.
SERIAL_MARK = "# run_suites: serial"

# How long a stopped suite gets to exit after TERM before its group is
# KILLed. RUN_SUITES_GRACE_SECONDS overrides it, so the runner's own test can
# prove the escalation without waiting this long.
GRACE_SECONDS = 5.0

# How long a KILLed suite's main process may take to be reaped. One in
# uninterruptible sleep (a dead network mount) would block a plain wait
# forever; past this bound it is left behind and named.
REAP_SECONDS = 5.0

# How often the scheduler looks for a finished suite or a pending signal.
POLL_SECONDS = 0.05

# QUIT too: its default action ends the runner without a word, leaving the
# suites running in their sessions and the scratch root behind.
EXIT_ON_SIGNAL = {signal.SIGHUP: 129, signal.SIGINT: 130, signal.SIGQUIT: 131,
                  signal.SIGTERM: 143}

# When a suite ends normally, waitid(WNOWAIT) sees that its main process
# exited while leaving it a zombie, so its pid, and with it the group id,
# cannot be reused while the group is KILLed. Where Python has no waitid the
# group is KILLed right after the reap, which leaves a window of a few
# microseconds for a reuse. CPython has os.waitid on macOS only from 3.13
# (3.9 to 3.12 compile it out on Apple; the os docs say "Changed in version
# 3.13"), so the 3.9 of the Command Line Tools takes that path. Stopping on a
# signal does not depend on it: stop_all() asks the group itself.
HAVE_WAITID = hasattr(os, "waitid") and hasattr(os, "WNOWAIT")


def emit(stream, text):
    """Write TEXT to STREAM as bytes. A suite path may not be valid UTF-8 (it
    came from argv through surrogateescape), and printing it must not raise."""
    stream.flush()
    stream.buffer.write(os.fsencode(text))
    stream.buffer.flush()


def to_devnull(stream):
    """Point STREAM's descriptor at /dev/null, so no later write can raise."""
    devnull = os.open(os.devnull, os.O_WRONLY)
    os.dup2(devnull, stream.fileno())
    os.close(devnull)


def err(msg):
    emit(sys.stderr, "ERROR: test: %s - failing closed\n" % msg)
    return 1


def plural(n, word):
    return "%d %s%s" % (n, word, "" if n == 1 else "s")


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
        with open("/proc/meminfo", encoding="ascii", errors="replace") as f:
            avail = parse_meminfo(f.read())
        if avail is not None:
            return avail
    except OSError:
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


def parse_meminfo(text):
    """Bytes in /proc/meminfo's MemAvailable line (the kernel prints KiB),
    or None when the line is missing or malformed."""
    m = re.search(r"^MemAvailable:\s+(\d+) kB$", text, re.M)
    return int(m.group(1)) * 1024 if m else None


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
        how = "%s, available memory unknown" % plural(cpus, "CPU")
    else:
        how = "%s, %d MiB available at %d MiB per suite" % (
            plural(cpus, "CPU"), avail // (1024 * 1024), SUITE_MEMORY_MIB)
    return pick_jobs(cpus, avail), how


def grace_seconds():
    """(seconds, None), or (None, an error)."""
    raw = os.environ.get("RUN_SUITES_GRACE_SECONDS", "")
    if not raw:
        return GRACE_SECONDS, None
    if not re.fullmatch(r"[0-9]{1,3}(\.[0-9]{1,3})?", raw):
        return None, "RUN_SUITES_GRACE_SECONDS must be a number of seconds below 1000, got %r" % raw
    return float(raw), None


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
        emit(sys.stderr, "WARN: test: could not remove the scratch root %s: %s\n" % (path, e))


def peak_rss_mib(ru, platform=sys.platform):
    # ru_maxrss is KiB on Linux and bytes on macOS.
    kib = ru.ru_maxrss // 1024 if platform == "darwin" else ru.ru_maxrss
    return kib // 1024


def read_all(fd):
    """Every byte of the file open at FD, read from its start with pread, so
    the offset the suite's processes still share with this descriptor is
    left alone."""
    chunks, off = [], 0
    while True:
        chunk = os.pread(fd, 1 << 16, off)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)
        off += len(chunk)


def kill_group(pgid, sig):
    # ESRCH: the group is already empty. EPERM: macOS refuses a signal to a
    # group whose only member left is a zombie. Neither leaves anything to stop.
    try:
        os.killpg(pgid, sig)
    except OSError:
        pass


class Stop:
    """What the signal handler records. Only flags: the scheduler acts on
    them between steps, so a signal can never land between a fork and the
    bookkeeping of the child it made."""

    def __init__(self):
        self.signum = None
        self.count = 0

    def handler(self, signum, _frame):
        if self.signum is None:
            self.signum = signum
        self.count += 1


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
    def __init__(self, suites, jobs, grace, stop):
        self.jobs = min(jobs, len(suites))
        self.grace = grace
        self.stop = stop
        width = len(str(len(suites)))
        self.runs = [Run(str(i).zfill(width), p, is_serial(p))
                     for i, p in enumerate(suites, 1)]
        self.root = None
        self.running = []

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
        # Kept open until report() has read it back through this same
        # descriptor: logs/ sits beside every suite's TMPDIR, and a suite
        # that swapped its log for a symlink or another file would print
        # whatever that names, were it opened again by its path. Read and
        # write, so that one descriptor serves both. Created, never reused:
        # an earlier suite can plant a symlink or a file at a later suite's
        # log path, and opening it would write through to whatever it names.
        # O_EXCL fails on any existing name, a symlink included (O_NOFOLLOW
        # is a second guard), and the FileExistsError fails the run closed
        # through the "could not start" path, before that suite runs.
        fd = os.open(os.path.join(self.root, "logs", run.index + ".log"),
                     os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC,
                     0o600)
        run.log = os.fdopen(fd, "w+b")
        try:
            # `--`: a suite path starting with `-` is a file, never an option.
            run.proc = subprocess.Popen(
                ["bash", "--", run.path], stdin=subprocess.DEVNULL, stdout=run.log,
                stderr=subprocess.STDOUT, env=env, start_new_session=True,
            )
        except BaseException:
            run.log.close()
            raise
        run.start = time.monotonic()
        self.running.append(run)
        emit(sys.stdout, "start %s\n" % run.path)

    def exited(self, run):
        """True once RUN's main process has exited, leaving it unreaped."""
        if not HAVE_WAITID:
            return False
        try:
            return os.waitid(os.P_PID, run.proc.pid,
                             os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
        except ChildProcessError:
            return True

    def collect(self, run):
        """Reap RUN's main process if it has exited; never blocks."""
        try:
            pid, status, ru = os.wait4(run.proc.pid, os.WNOHANG)
        except ChildProcessError:
            pid, status, ru = run.proc.pid, 255 << 8, None
        if pid == 0:
            return False
        # wait4, not Popen.wait: its rusage is the peak RSS the `done` line
        # prints. returncode is set by hand so Popen never waits again.
        run.proc.returncode = run.code = os.waitstatus_to_exitcode(status)
        run.seconds = time.monotonic() - run.start
        run.rss = peak_rss_mib(ru) if ru is not None else 0
        return True

    def reap(self):
        """Collect every suite that has ended; returns them in end order.
        What a suite left running in its group is KILLed as it is reaped."""
        done = []
        for run in list(self.running):
            if HAVE_WAITID:
                if not self.exited(run):
                    continue
                kill_group(run.proc.pid, signal.SIGKILL)
                # Non-blocking even here: should waitid ever report an exit
                # that wait4 cannot collect yet, the next poll retries.
                if not self.collect(run):
                    continue
            else:
                if not self.collect(run):
                    continue
                kill_group(run.proc.pid, signal.SIGKILL)
            self.running.remove(run)
            done.append(run)
        return done

    def report(self, run, verdict=None):
        if verdict is None:
            if run.code == 0:
                verdict = "ok"
            elif run.code is None:
                verdict = "FAILED (never reaped)"
            elif run.code < 0:
                verdict = "FAILED (killed by signal %d)" % -run.code
            else:
                verdict = "FAILED (exit %d)" % run.code
        try:
            body = read_all(run.log.fileno())
        except OSError as e:
            body = ("(its output could not be read: %s)\n" % e).encode()
        finally:
            run.log.close()
        if body and not body.endswith(b"\n"):
            body += b"\n"
        out = sys.stdout.buffer
        sys.stdout.flush()
        out.write(os.fsencode("run %s\n" % run.path))
        out.write(body)
        out.write(os.fsencode("done %s: %s in %.1fs, peak RSS %d MiB\n"
                              % (run.path, verdict, run.seconds, run.rss)))
        out.flush()

    def stop_all(self):
        """TERM every running suite's group, wait until each group is empty
        or the grace period is over, KILL what is left, and reap the main
        processes. Returns the suites it stopped.

        A group is KILLed only once the grace period is over (or a second
        signal cut it short), never as soon as its main process exits: a
        suite may run a nested runner in its group, which needs that time to
        stop its own suites, each in a session of its own, out of this
        runner's reach. A main process is reaped as soon as it exits; its
        group id stays in use, and so cannot be reused, for as long as any
        member is left. Whether one is left is asked again each poll, and
        once more right before the KILL, so a group that emptied during the
        last poll's sleep is skipped, not KILLed; one that empties between
        that probe and the KILL leaves the same few-microsecond window for a
        reuse as a run without waitid."""
        stopped, self.running = self.running, []
        if not stopped:
            return []
        for run in stopped:
            kill_group(run.proc.pid, signal.SIGTERM)
        live = list(stopped)          # groups that may still have members
        deadline = time.monotonic() + self.grace
        while live and time.monotonic() < deadline and self.stop.count < 2:
            still = []
            for run in live:
                if run.code is None and not self.collect(run):
                    still.append(run)       # the main process still runs
                    continue
                try:
                    os.killpg(run.proc.pid, 0)
                except ProcessLookupError:
                    continue                # the group is empty: done
                except OSError:
                    pass                    # EPERM: members, not ours
                still.append(run)
            live = still
            if live:
                time.sleep(POLL_SECONDS)
        for run in live:
            try:
                os.killpg(run.proc.pid, 0)
            except ProcessLookupError:
                continue                    # emptied since the last poll
            except OSError:
                pass
            kill_group(run.proc.pid, signal.SIGKILL)
        pending = [r for r in stopped if r.code is None]
        deadline = time.monotonic() + REAP_SECONDS
        while pending:
            pending = [r for r in pending if not self.collect(r)]
            if not pending or time.monotonic() >= deadline:
                break
            time.sleep(POLL_SECONDS)
        for run in pending:
            emit(sys.stderr, "WARN: test: %s (pid %d) did not exit after KILL; left behind\n"
                 % (run.path, run.proc.pid))
        return stopped

    def abort(self, why):
        """Stop every running suite and print each one's block."""
        for run in self.stop_all():
            self.report(run, "INTERRUPTED (%s)" % why)

    def schedule(self):
        """Run every suite; returns the exit code."""
        started = time.monotonic()
        # Serial suites first: they need an empty pool, which costs nothing
        # before the pool has started and a drain of it anywhere later.
        pending = [r for r in self.runs if r.serial] + [r for r in self.runs if not r.serial]
        while pending or self.running:
            if self.stop.signum is not None:
                return self.interrupted()
            for run in self.reap():
                self.report(run)
            while pending and self.stop.signum is None:
                nxt = pending[0]
                serial_busy = any(r.serial for r in self.running)
                if serial_busy or len(self.running) >= self.jobs:
                    break
                if nxt.serial and self.running:
                    break
                pending.pop(0)
                try:
                    self.launch(nxt)
                except BrokenPipeError:
                    raise                   # stdout closed: main() says so
                except OSError as e:
                    err("could not start %s (%s)" % (nxt.path, e))
                    self.abort("the run stopped: a suite could not start")
                    return 1
            time.sleep(POLL_SECONDS)
        if self.stop.signum is not None:
            return self.interrupted()
        return self.summary(time.monotonic() - started)

    def interrupted(self):
        # A suite that ended before the signal keeps its own verdict.
        for run in self.reap():
            self.report(run)
        name = signal.Signals(self.stop.signum).name
        self.abort("by %s" % name)
        emit(sys.stderr, "test: interrupted by %s; every running suite's process group "
             "was stopped (a process that left its group, with setsid or set -m, "
             "or as a daemon, is out of reach)\n" % name)
        return EXIT_ON_SIGNAL[self.stop.signum]

    def summary(self, wall):
        lines = ["test: suite times, slowest first:\n"]
        for run in sorted(self.runs, key=lambda r: r.seconds, reverse=True):
            lines.append("  %7.1fs  %s\n" % (run.seconds, run.path))
        lines.append("test: wall time %.1fs, %d at a time\n" % (wall, self.jobs))
        emit(sys.stdout, "".join(lines))
        failed = [r.path for r in self.runs if r.code != 0]
        if failed:
            emit(sys.stderr, "test: FAILED: %s\n" % " ".join(failed))
            return 1
        n = len(self.runs)
        emit(sys.stdout, "test: all %d test files passed\n" % n if n != 1
             else "test: 1 test file passed\n")
        return 0


def main(argv):
    # Handlers first: reading the memory can take a while (vm_stat), and a
    # Ctrl-C then must still end the run with its own exit code. The
    # scheduler checks for a signal before it starts any suite.
    stop = Stop()
    for sig in EXIT_ON_SIGNAL:
        signal.signal(sig, stop.handler)
    if not argv:
        # Not a failure: TEST_FILES is a wildcard, empty only in a tree with
        # no suites, and the recipe has always said so and exited 0.
        emit(sys.stdout, "test: no tests found\n")
        return 0
    jobs, how = job_count()
    if jobs is None:
        return err(how)
    grace, problem = grace_seconds()
    if grace is None:
        return err(problem)
    runner = Runner(argv, jobs, grace, stop)
    try:
        rc = runner.setup()
        if rc == 0:
            serial = sum(1 for r in runner.runs if r.serial)
            emit(sys.stdout, "test: %s (%d serial), %d at a time (%s)\n"
                 % (plural(len(runner.runs), "suite"), serial, runner.jobs, how))
            rc = runner.schedule()
        return rc
    except BrokenPipeError:
        # Whoever read stdout is gone (`head`, say). Point stdout at
        # /dev/null, so the cleanup below and the interpreter's own flush at
        # exit cannot raise again, and say why on stderr.
        to_devnull(sys.stdout)
        try:
            return err("stdout was closed (a broken pipe); stopping the run "
                       "and its running suites")
        except BrokenPipeError:
            # stderr went to the same reader (`2>&1 | head`): point it at
            # /dev/null too, so the WARN lines of the cleanup and the flush
            # at exit cannot raise, and the exit stays 1, never Python's 120.
            to_devnull(sys.stderr)
            return 1
    finally:
        # Runs on every path, a failed setup and an exception included. A
        # signal during cleanup only sets a flag, so it cannot cut it short.
        for run in runner.stop_all():
            run.log.close()
        if runner.root is not None:
            remove_tree(runner.root)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
