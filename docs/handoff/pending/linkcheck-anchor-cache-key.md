# linkcheck-anchor-cache-key

The test drops the anchor cache key without asserting that it exists first, so
a renamed key would make the drop a silent no-op.

Came from: #73 (feat(test): run the suites in parallel under a memory-aware
job cap), round 3 of the pre-merge ship gate (reviewer and security personas),
a ship round being one run of it.

Why open: Test hygiene only.

Fix: Assert the key exists before dropping it.
