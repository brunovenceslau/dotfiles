# ghostty-test-message

tests/ghostty_test.sh reports a seven-digit hex value from the inline-comment
check instead of the allowlist check, so the message misleads.

Came from: #69 (conf(ghostty): Add new themes), round 3 of the pre-merge ship
gate (reviewer and security personas), a ship round being one run of it.

Why open: It is cosmetic; the theme is still rejected.

Fix: Reorder the two checks or reword the message.
