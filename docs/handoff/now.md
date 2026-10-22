# Current state

## Where we stopped

State at 2026-10-22. The stack docs count a GitHub stack only while its
API lists it, see `01m5jnsq6frwdckhqvkqvs4bne` ("Stack docs count a GitHub
stack only while its API lists it"). The runner test's fork races are
fixed, see `01m5gvx0fx6xdwr3g1sxavbfqs` ("The obeyer test forks its sleep
before it says ready"). The earlier efforts are all merged. Their records
are in done/.

## Next steps

1. Watch the hosted macOS arm64 leg over the next runs: the obeyer and
   "exception stops the group" cases confirm the fork-race fix by staying
   green; a failure now names the members left.
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

- Branch `docs/stack-condition-api`: the stack docs and this checkpoint,
  until its PR merges.

Branch and PR state is not recorded here: measure it with
`~/.sbx-kit/claude-home/bin/handoff_state.py`.
