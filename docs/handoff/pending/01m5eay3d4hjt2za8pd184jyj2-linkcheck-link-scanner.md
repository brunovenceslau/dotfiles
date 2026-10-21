# linkcheck-link-scanner

After the tag scanner, `tests/linkcheck_test.sh` still peaks at 670 MiB on
the macOS arm64 CI leg (1294 MiB before it), above the 384 MiB per-suite
budget of `tests/run_suites.py`; 85 MiB on Linux. The rest is the
backtracking stack of `LINK` and `HEADING_LINK` in `tests/linkcheck.py`:
30 to 48 MiB of tracemalloc peak on the 200 KB growth shapes h18 to h20,
h24, h35 and h48 (unclosed destinations and titles), about 240 bytes per
input character.

Came from: the linkcheck tag scanner, Done
`01m5ea79k5bjycqcdzf0fw1f49` ("linkcheck reads open tags with a scanner
bounded by one token").

Why open: a small arm64 Mac cannot run the suite inside its memory budget.

Fix: read a link's destination and title the way `_tag_walk` reads a tag,
one token at a time with single character class runs and `str.find`, and
extend the tracemalloc case of `tests/linkcheck_test.sh` to those shapes.
The docs/development.md Deferred decisions row "Tell an out-of-memory kill
apart from an expected failure in `make test`" holds the figures.
