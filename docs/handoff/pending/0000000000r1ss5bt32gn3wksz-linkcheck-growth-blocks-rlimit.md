# linkcheck-growth-blocks-rlimit

The h60-h64 and blank_spans blocks of the linkcheck test have no RLIMIT_CPU,
so a regression there would hang instead of naming the shape.

Came from: #73 (feat(test): run the suites in parallel under a memory-aware
job cap), round 3 of the pre-merge ship gate (reviewer and security personas),
a ship round being one run of it; predates the PR.

Why open: Predates the runner change.

Fix: Run those blocks under the same per-run RLIMIT_CPU.
