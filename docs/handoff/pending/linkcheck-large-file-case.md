# linkcheck-large-file-case

No functional case sits near `MAX_FILE_BYTES`. A gate that silently skipped
large files would pass.

Came from: #73 (feat(test): run the suites in parallel under a memory-aware
job cap), round 3 of the pre-merge ship gate (reviewer and security personas),
a ship round being one run of it.

Why open: The limit is covered only by inspection.

Fix: Add a case just under and just over the limit.
