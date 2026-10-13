# runner-quit-mutant-timeout

The QUIT mutant fails as a timeout rather than a wrong exit code, and leaves
orphans in that mutant run.

Came from: #73 (feat(test): run the suites in parallel under a memory-aware
job cap), round 3 of the pre-merge ship gate (reviewer and security personas),
a ship round being one run of it.

Why open: Test hygiene only.

Fix: Bound the mutant run so it reports the exit code and cleans up.
