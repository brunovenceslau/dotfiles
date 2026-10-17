# runner-stderr-broken-pipe

When only stderr is a closed pipe, a WARN in `finally` can skip the cleanup
(inferred). A stderr BrokenPipeError is also handled as if it came from
stdout. Two broken-pipe edges turn the exit code into 1, or end in a
traceback.

Came from: #73 (feat(test): run the suites in parallel under a memory-aware
job cap), round 3 of the pre-merge ship gate (reviewer and security personas),
a ship round being one run of it.

Why open: Rare: only stderr closed.

Fix: Handle stdout and stderr separately and keep the cleanup in a path that
cannot raise.
