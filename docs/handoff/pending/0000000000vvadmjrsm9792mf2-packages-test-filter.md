# packages-test-filter

tests/packages_test.sh filters lines through the installer's own regex, so a
malformed manifest line is dropped instead of failing the test.

Came from: #70 (chore(packages): pin gh-stack v0.2.1, and say where GitHub
reports a stack), round 3 of the pre-merge ship gate (reviewer and security
personas), a ship round being one run of it; predates the PR.

Why open: The filter and the code under test share one regex.

Fix: Filter with an independent rule, or fail on any line that is neither
blank, a comment nor a valid entry.
