# Current state

## Where we stopped

State at 2026-10-20. The handoff items are named by a ULID and the slug of
their title, and the first scheduled Intel run passed, see
`01m5dfp12zhd41fn6x4ynzndcv` ("Handoff items named by a ULID, first
scheduled Intel run green"). Main is green. The earlier efforts are all
merged. Their records are in done/.

## Next steps

1. The `fix/parallel-flakes` leftover, `00000000009s5pskjy2cayrq5g`
   ("host-identity-signal-during-gh-start").
2. `0000000000p5zw6r8s287k3net` ("linkcheck-tag-scanner"), which lowers
   linkcheck's peak memory.
3. Then the Ghostty items (`ghostty-test-message`,
   `ghostty-allowlist-breadth`, `gotham-autosuggest-contrast`).
4. Then the packages and stack-docs items (`packages-test-filter`,
   `stack-condition-api` and the `ghstack-*` items).
5. The `runner-*` and remaining `linkcheck-*` items, as the runner or
   linkcheck are next touched.
6. `0000000000qpgraw9h5qqw1vdy` ("handoff-check-gate"), now that the layout
   has its ids.
7. Check the Intel leg's weekly run each Monday until it has a track
   record.

## Open for the operator

Whether the one open commit of `fix/parallel-flakes` gets a PR. It touches
the `security-model` surface "The SSH signing setup", so the PR needs the
maintainer's agreement in an issue. Recommendation: open its PR with the
surface ticked and the agreement issue linked, or drop the branch.

## In flight

- Branch `fix/parallel-flakes`: one commit left, 1e04ebd (end gh when a
  signal lands while it starts). See item `00000000009s5pskjy2cayrq5g`.

Branch and PR state is not recorded here: measure it with
`~/.sbx-kit/claude-home/bin/handoff_state.py`.
