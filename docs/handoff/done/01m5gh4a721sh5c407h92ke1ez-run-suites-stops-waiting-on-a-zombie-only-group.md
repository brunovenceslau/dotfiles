# run_suites stops waiting on a zombie-only group

Session of 2026-10-21.

- The in-process case "grace no KILL for an obeyer" of
  `tests/run_suites_test.sh` failed twice on the hosted macOS arm64 leg:
  run 39488918611 (main, d019849, 2026-10-20) and run 39698323746 (#88,
  2026-10-22 00:13 UTC), each with a KILL at the end of the grace while
  bash had been reaped with its TERM status. Neither diff touched the
  runner.
- Most likely cause, found in review: `stop_all` in `tests/run_suites.py`
  read an EPERM from its `killpg(pgid, 0)` probe as live members, while
  `kill_group` beside it already documented that macOS answers EPERM for a
  group whose only member left is a zombie (here the killed `sleep`, waiting
  for launchd). So a stopped suite was held to the grace's end and then
  KILLed. The new `group_alive` reads EPERM as nothing left to stop, in both
  probes; a live member of a group the runner made is its own, so a signal
  reaches it.
- Reproduced on Linux first: a new case stubs the probe to answer EPERM,
  and before the fix it failed exactly as CI did (KILL at 1120.05 on the
  test's clock); after it, no KILL and the TERM status kept.

Not confirmed on macOS: the reproduction stubs the probe, and the EPERM
reading rests on the comment beside `kill_group`. It is confirmed when the
hosted macOS arm64 leg stays green over several runs; if the case fails
there again, record the probe's errno before anything else.
