# Current state

## Where we stopped

State at 2026-10-21. The signal hold in gh_token landed as #83 and the
`fix/parallel-flakes` branch is gone, see `01m5ea79j5kqryrnv2mkgedg9k`
("Signal hold in gh_token landed, fix/parallel-flakes retired").
linkcheck reads open tags with a scanner bounded by one token, see
`01m5ea79k5bjycqcdzf0fw1f49` ("linkcheck reads open tags with a scanner
bounded by one token"). The earlier efforts are all merged. Their records
are in done/.

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

- Branch `perf/linkcheck-tag-scanner`: the tag scanner and this
  checkpoint, until its PR merges.

Branch and PR state is not recorded here: measure it with
`~/.sbx-kit/claude-home/bin/handoff_state.py`.
