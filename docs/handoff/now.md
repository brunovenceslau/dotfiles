# Current state

## Where we stopped

State at 2026-10-21. The Ghostty test names a malformed theme colour as a
value, see `01m5efgqxm3y9v8p7kfydnc48q` ("Ghostty test names a malformed
theme colour as a value"). linkcheck's peak is inside its budget on the
macOS arm64 leg and on Linux. The earlier efforts are all merged. Their
records are in done/.

## Next steps

1. The packages and stack-docs items (`packages-test-filter`,
   `stack-condition-api` and the `ghstack-*` items).
2. The `runner-*` and remaining `linkcheck-*` items, as the runner or
   linkcheck are next touched.
3. `0000000000qpgraw9h5qqw1vdy` ("handoff-check-gate"), now that the layout
   has its ids.
4. Check the Intel leg's weekly run each Monday until it has a track
   record.
5. The other Ghostty items wait for their triggers:
   `ghostty-allowlist-breadth` (a theme needs a wider colour form) and
   `gotham-autosuggest-contrast` (gotham-default is wired in).

## Open for the operator

Nothing.

## In flight

- Branch `fix/ghostty-test-message`: the test fix and this checkpoint,
  until its PR merges.

Branch and PR state is not recorded here: measure it with
`~/.sbx-kit/claude-home/bin/handoff_state.py`.
