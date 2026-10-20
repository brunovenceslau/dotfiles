# memory-row-sigkill-wording

In the memory row of Deferred decisions in docs/development.md, a signal 9 is
not always an out-of-memory kill.

Came from: #73 (feat(test): run the suites in parallel under a memory-aware
job cap), round 6 of the pre-merge ship gate (reviewer and security personas),
a ship round being one run of it (Nit).

Why open: The trigger works either way.

Fix: Reword the trigger as "(as an out-of-memory kill is)".
