# feat(test): run the suites in parallel under a memory-aware job cap

PR #73 (feat(test): run the suites in parallel under a memory-aware job cap)
merged on 2026-10-13 as 46af3bb. `make test` now runs the suites through
`tests/run_suites.py` (Python 3, standard library only), one process group and
session per suite, with min(CPUs, available memory / 384 MiB) jobs.
`tests/run_suites_test.sh` drives the real runner. The linkcheck hostile-input
case now compares CPU-time growth per shape instead of a 60 s wall-clock
limit.

Gates: the ship gate is the pre-merge review by reviewer and security
personas, and a ship round is one run of it. Round 1 GO; round 2 NO-GO (a gawk
flake and capped items, all fixed); round 3 GO; rounds 4 and 5 NO-GO on the
memory row of Deferred decisions in docs/development.md (a fired trigger, then
a trigger already met by the row's own figures), fixed by re-deferring with
new triggers; round 6 GO. Hosted CI at c965e50 was red on macOS Intel: the
linkcheck 60 s limit under 4 parallel jobs, fixed by the CPU-growth check.
Hosted CI at 0abd004 was green.

Hosted timings: the macOS Intel job went from 28m18s to 20m35s, and the arm64
job from 13m10s to 8m34s. Splitting `check_patterns_test` (946 s on Intel) is
the remaining lever, recorded in Deferred decisions. The capped findings are
in pending/ (`runner-*`, `linkcheck-*`, `memory-row-sigkill-wording`). What
was not tested is listed in the "Not tested" section of #73's description.
