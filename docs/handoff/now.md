# Current state

## Where we stopped

State at 2026-10-21. The packages test checks the raw gh-extensions lines,
see `01m5ep10ayg2gza9hnv1rmh1mk` ("packages test checks the raw
gh-extensions lines"). The earlier efforts are all merged. Their records
are in done/.

## Next steps

1. The stack-docs items (`stack-condition-api` and the `ghstack-*`
   items).
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

- Branch `feat/host-maxfiles`: `install.sh maxfiles` and this checkpoint,
  until its PR merges.

Branch and PR state is not recorded here: measure it with
`~/.sbx-kit/claude-home/bin/handoff_state.py`.
