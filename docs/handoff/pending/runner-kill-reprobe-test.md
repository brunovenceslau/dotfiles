# runner-kill-reprobe-test

The re-probe before KILL has no test. Its 50 ms window cannot be staged
easily.

Came from: #73 (feat(test): run the suites in parallel under a memory-aware
job cap), round 3 of the pre-merge ship gate (reviewer and security personas),
a ship round being one run of it.

Why open: Only a fake clock could stage it.

Fix: Add a test on a fake clock, or accept the gap in writing.
