# Current state

## Where we stopped

State at 2026-10-15, main at 46af3bb (PR #73, the parallel test runner,
merged). #73's own checks were green on both macOS legs. The CI run on main
after the merge (46af3bb, run 38398695919) failed both legs, in cases not
seen on #73's own checks: macOS Intel in `tests/host_identity_test.sh` ("the
zsh tree is not a loose object"), and macOS arm64 in
`tests/linkcheck_test.sh` ("a quadratic scan must fail the growth ratio on
h26.md"). The fix is written, not yet gated (see In flight). The
earlier efforts (PRs #64 to #71) are all merged. Their records are in done/.

## Next steps

1. Finish the fix for the CI run on main at 46af3bb: `make local-ci
   STRICT=1`, the ship gate, then its PR (see In flight).
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

- Branch `fix/parallel-flakes`: three commits, each explaining its cause
  in its body. They stop git's auto repack from racing the fixture clones,
  build the quadratic mutant out of the gate's own scan, and end gh when a
  signal lands while it starts. The last one changes `lib/host_identity.py`:
  check whether it touches the `security-model` surface, and if so the PR
  asks for that approval. Not yet run: `make local-ci STRICT=1` and the
  ship gate.
- This move of the handoff notes into docs/handoff/, on branch
  `docs/handoff-migration`.

Branch and PR state is not recorded here: measure it with
`~/.sbx-kit/claude-home/bin/handoff_state.py`.
