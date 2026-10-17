# linkcheck-backstop-message

When the 300 s backstop fires, the message does not say how much CPU time was
used.

Came from: #73 (feat(test): run the suites in parallel under a memory-aware
job cap), round 3 of the pre-merge ship gate (reviewer and security personas),
a ship round being one run of it.

Why open: Diagnostics only.

Fix: Print the CPU time used when the backstop fires.
