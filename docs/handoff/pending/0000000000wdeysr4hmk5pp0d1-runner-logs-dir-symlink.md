# runner-logs-dir-symlink

A suite that swaps `logs/` for a symlink makes a later suite's log land
outside the scratch root. The suites run as the same user.

Came from: #73 (feat(test): run the suites in parallel under a memory-aware
job cap), round 3 of the pre-merge ship gate (reviewer and security personas),
a ship round being one run of it.

Why open: The threat is a hostile suite, which already has the user's rights.

Fix: Open `logs/` once with `O_DIRECTORY|O_NOFOLLOW` and create each log
through `dir_fd`.
