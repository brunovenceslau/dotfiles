# linkcheck-tag-scanner

A per-attribute tag scanner would lower linkcheck's peak memory. The plan is
recorded in the Deferred decisions row "Tell an out-of-memory kill apart from
an expected failure in `make test`" in docs/development.md.

Came from: #73 (feat(test): run the suites in parallel under a memory-aware
job cap); planned.

Why open: The row holds the figures and the triggers.

Fix: See that row.
