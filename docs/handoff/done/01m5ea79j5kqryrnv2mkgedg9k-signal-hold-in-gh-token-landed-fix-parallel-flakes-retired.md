# Signal hold in gh_token landed, fix/parallel-flakes retired

Session of 2026-10-21. Closes pending `00000000009s5pskjy2cayrq5g`
("host-identity-signal-during-gh-start").

- #83 (fix(identity): end gh when a signal lands while it starts), merged
  as 1b8f5d7. The last commit of `fix/parallel-flakes` (1e04ebd), picked
  onto main, plus a review commit: a failing preexec_fn answers "unknown"
  instead of a traceback, and the units case requires SigBlk to have been
  read on Linux (a mutant without the preexec_fn fails it, SigBlk 4003).
  It touches the `security-model` surface "The SSH signing setup"; the
  agreement is issue #82. Gates: `make lint` and `make local-ci STRICT=1`
  green locally (Linux); code-reviewer and security-auditor (sonnet)
  approved; hosted local-ci (macos-arm64) green.
- The remote branch `fix/parallel-flakes` was deleted after the merge:
  its three commits are in main through #75, #76 and #83.

Left open, by choice: no test covers a caller that already had the
unwinding signals blocked, and on macOS (no /proc) the mask half of the
units case is not checked.
