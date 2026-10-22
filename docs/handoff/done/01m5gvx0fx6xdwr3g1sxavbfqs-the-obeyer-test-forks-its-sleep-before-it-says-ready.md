# The obeyer test forks its sleep before it says ready

Session of 2026-10-22.

- "grace no KILL for an obeyer" failed a third time on the hosted macOS
  arm64 leg, run 39718076907 (#88 rebased on bc267ab), with the runner fix
  of `01m5gh4a721sh5c407h92ke1ez` ("run_suites stops waiting on a
  zombie-only group") already in. Same output: a KILL at 1120.05 on the
  test's clock, and bash reaped with its TERM status (the "status kept"
  case passed). So the EPERM reading recorded there was not the cause of
  these runs.
- Cause (the outcome reproduced on Linux by sending the TERM to bash
  alone; the XNU side read from source): the test's `obey.sh` wrote its
  ready file and only then forked `sleep`. A group TERM that lands while
  bash forks reaches bash but can miss the new child on macOS. Linux
  delays such a signal until the child exists too (kernel/fork.c, v6.12,
  around line 2185); XNU's fork (bsd/kern/kern_fork.c, xnu-11215.1.10) has
  no such step. The orphaned `sleep 300` kept the group alive to the
  grace's end, and the runner KILLed it, as it should. The repro printed
  the CI output exactly.
- Fix, in the test (plus a docstring in `tests/run_suites.py`): both
  obeyers fork their sleep before they say ready and then `wait`, so no
  fork can overlap the TERM. A KILL in the clocked cases now records the
  group's members, and the obeyer check prints them, so a repeat names
  what was left.
- This PR's first CI run (39844046040) failed "exception stops the group"
  instead, first seen there in the last 30 runs. `slowpid.sh` had the same
  order (its pid, then the fork), and the test probed the group right after
  the cleanup, reading any error, EPERM included, as alive, without naming
  it. On Linux the probe always saw ESRCH, the missed TERM included, so the
  errno on macOS is not known. Most likely a killed member still waited
  for launchd. `slowpid.sh` now forks first, and the probe waits up to 5s
  for ESRCH and otherwise prints the errno and the members left; a mutant
  whose cleanup stops nothing still fails it.
- `group_alive`'s EPERM handling stays: it rests on `kill_group`'s comment
  and is harmless; its docstring no longer cites these runs.

Not confirmed on macOS: the XNU side is read from the source, not
measured. It is confirmed when the hosted macOS arm64 leg stays green over
several runs; if the case fails again, its message now lists the members
left at the KILL.
