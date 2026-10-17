# runner-pread-offset-test

No test proves that pread, rather than seek and read, is what keeps the file
offset the suites share.

Came from: #73 (feat(test): run the suites in parallel under a memory-aware
job cap), round 3 of the pre-merge ship gate (reviewer and security personas),
a ship round being one run of it.

Why open: A mutant swapping them would survive.

Fix: Add a test that fails when the offset moves.
