# ghostty-allowlist-breadth

Some valid Ghostty forms are rejected by tests/ghostty_test.sh on purpose:
3-digit hex, named colours and palette indexes 16-255.

Came from: #69 (conf(ghostty): Add new themes), round 3 of the pre-merge ship
gate (reviewer and security personas), a ship round being one run of it.

Why open: No theme needs one yet.

Fix: Widen the pattern when a theme needs one.
