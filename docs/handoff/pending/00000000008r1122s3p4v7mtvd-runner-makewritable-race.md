# runner-makewritable-race

`make_writable` has a gap between scandir and chmod. It is reachable only by a
stray process that is already out of reach.

Came from: #73 (feat(test): run the suites in parallel under a memory-aware
job cap), round 3 of the pre-merge ship gate (reviewer and security personas),
a ship round being one run of it.

Why open: Not exploitable in practice.

Fix: Close the gap with fd-based chmod, or record the risk as accepted.
