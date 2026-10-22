# packages test checks the raw gh-extensions lines

Session of 2026-10-21. Closes pending `0000000000vvadmjrsm9792mf2`
("packages-test-filter").

- `tests/packages_test.sh` read `packages/gh-extensions.txt` through the
  installer's own `_packages_gh_ext_list`, which drops a malformed line
  silently, and then looked for malformed lines in its output: it could
  never find one. Reproduced by appending `github/gh-oops` and
  `owner/repo latest`: the test still passed.
- It now checks the raw lines against a rule written in the test: blank, a
  comment, or `owner/repo` with a `vX.Y.Z` or 40-hex pin and an optional
  trailing comment. A missing pin, a floating `latest`, a third token, a
  dash-led owner and a trailing CR each fail it, with the line number.
