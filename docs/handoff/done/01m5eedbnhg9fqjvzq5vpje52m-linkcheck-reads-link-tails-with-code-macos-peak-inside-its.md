# linkcheck reads link tails with code, macOS peak inside its budget

Session of 2026-10-21. Closes pending `01m5eay3d4hjt2za8pd184jyj2`
("linkcheck-link-scanner").

- #84 (perf(linkcheck): read open tags with a scanner bounded by one
  token), merged as 019d1f9, see `01m5ea79k5bjycqcdzf0fw1f49` ("linkcheck
  reads open tags with a scanner bounded by one token").
- #85 (perf(linkcheck): read link tails with code bounded by one token),
  merged as 9f7b1bd:
  `LINK`, `HEADING_LINK`, `HEADING_IMAGE` and `REFDEF` keep a regex for
  their head only; `LinkPattern` reads the destination (a depth count for
  nested parentheses) and title with code. A differential fuzz against
  main agreed on about 1.5 million inputs, and the reviewer's own on
  900000 more. The tracemalloc case covers five link shapes.
- `tests/linkcheck_test.sh` peak RSS on the macOS arm64 leg: 1294 MiB on
  main before #84, 670 MiB after it, 138 MiB after #85, inside the
  384 MiB per-suite budget. The heaviest suite there is now
  `tests/check_patterns_test.sh` at 230 MiB.

Lesson: re keeps about 290 bytes of stack for every repetition of a
group, whatever the group holds, so a bound on memory needs code (or a
single character class) wherever a group repeats per input character.
