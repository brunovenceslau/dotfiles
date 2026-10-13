# linkcheck-hostile-main-run

Run `main()` once over a few 8x hostile shapes, to keep the exit contract and
`tty_safe` covered on hostile input.

Came from: #73 (feat(test): run the suites in parallel under a memory-aware
job cap), round 3 of the pre-merge ship gate (reviewer and security personas),
a ship round being one run of it.

Why open: The growth check calls the scanner, not `main()`.

Fix: Add the one run to tests/linkcheck_test.sh.
