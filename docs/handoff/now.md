# Current state

## Where we stopped

State at 2026-10-13, main at 46af3bb (PR #73, the parallel test runner,
merged). #73's own checks were green on both macOS legs. The CI run on main
after the merge (46af3bb, run 38398695919) failed both legs, intermittently:
macOS Intel in `tests/host_identity_test.sh` ("the zsh tree is not a loose
object"), and macOS arm64 in `tests/linkcheck_test.sh` ("a quadratic scan must
fail the growth ratio on h26.md"). A fix is in flight. The earlier efforts
(PRs #64 to #71) are all merged. Their records are in done/.

## Next steps

1. The fix for the two intermittent failures of the CI run on main at
   46af3bb (see Where we stopped and In flight).
2. `linkcheck-tag-scanner` (lowers linkcheck's peak memory).
3. Then the Ghostty items (`ghostty-test-message`,
   `ghostty-allowlist-breadth`, `gotham-autosuggest-contrast`).
4. Then the packages and stack-docs items (`packages-test-filter`,
   `stack-condition-api` and the `ghstack-*` items).
5. The `runner-*` and remaining `linkcheck-*` items, as the runner or
   linkcheck are next touched.
6. `handoff-check-gate` when the layout of this directory has settled.

## Open for the operator

Nothing blocking. Items outside this repository were handed on (2026-10-13).

## In flight

This move of the handoff notes into docs/handoff/, and a fix for the two
intermittent failures of the CI run on main at 46af3bb, named under Where we
stopped (PR numbers recorded when opened).
