# Current state

## Where we stopped

State at 2026-10-21. linkcheck reads tags and link tails with code, and
`tests/linkcheck_test.sh` peaks at 138 MiB on the macOS arm64 leg, inside
its budget, see `01m5eedbnhg9fqjvzq5vpje52m` ("linkcheck reads link tails
with code, macOS peak inside its budget"). The earlier efforts are all
merged. Their records are in done/.

## Next steps

1. The Ghostty items (`ghostty-test-message`, `ghostty-allowlist-breadth`,
   `gotham-autosuggest-contrast`).
2. Then the packages and stack-docs items (`packages-test-filter`,
   `stack-condition-api` and the `ghstack-*` items).
3. The `runner-*` and remaining `linkcheck-*` items, as the runner or
   linkcheck are next touched.
4. `0000000000qpgraw9h5qqw1vdy` ("handoff-check-gate"), now that the layout
   has its ids.
5. Check the Intel leg's weekly run each Monday until it has a track
   record.

## Open for the operator

Nothing.

## In flight

- Branch `docs/handoff-checkpoint-2026-10-21`: this checkpoint, until its
  PR merges.

Branch and PR state is not recorded here: measure it with
`~/.sbx-kit/claude-home/bin/handoff_state.py`.
