# ghstack-web-merge-recheck

The web Merge-button route in docs/stacked-prs.md has no re-check step. A
stack dissolved on the web would make the click a plain merge.

Came from: #70 (chore(packages): pin gh-stack v0.2.1, and say where GitHub
reports a stack), round 3 of the pre-merge ship gate (reviewer and security
personas), a ship round being one run of it.

Why open: The doc covers only the CLI re-check.

Fix: Add a step: confirm the PR page still shows the stack.
