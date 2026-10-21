# linkcheck reads open tags with a scanner bounded by one token

Session of 2026-10-21. Closes pending `0000000000p5zw6r8s287k3net`
("linkcheck-tag-scanner").

- `tests/linkcheck.py` reads `<a` and `<img` open tags with `_tag_walk`, a
  generator that reads one token at a time, instead of the HTML_OPEN
  regex, whose backtracking stack held about 300 bytes per character of
  one tag. On 800 KB tags the peak fell from 212 to 295 MiB to under
  1 MiB; the suite's peak RSS from 143 MiB to about 85 MiB on Linux and
  from 1294 MiB to 670 MiB on the macOS arm64 leg, still above its
  384 MiB budget there: the rest is pending `01m5eay3d4hjt2za8pd184jyj2`
  ("linkcheck-link-scanner").
- A differential fuzz of the old and new readers (about 2.6 million random
  inputs) agreed everywhere except where the old regex took a second
  parse, a bare value shortened before a `/`; the scanner reads a bare
  value whole, as HTML5 does.
- `tests/linkcheck_test.sh` asserts the bound with tracemalloc, and its
  exponential mutant is now an appended term, like the quadratic one.
- The docs/development.md Deferred decisions row "Tell an out-of-memory
  kill apart from an expected failure in `make test`" records the change;
  its question stays deferred.

Lesson: tracemalloc sees re's backtracking stack, so a memory bound on a
regex can be tested the same way on every platform.
