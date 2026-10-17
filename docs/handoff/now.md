# Current state

## Where we stopped

State at 2026-10-17. The flakes seen on main on 2026-10-13 are fixed and
main is green (done/0005.md). Intel macOS support is best effort: its CI leg
runs weekly and on demand, not on pull requests
(decisions/intel-macos-support-is-best-effort.md). The earlier efforts are
all merged. Their records are in done/.

## Next steps

1. Check the first scheduled Monday Intel run (`intel.yml`).
2. The `fix/parallel-flakes` leftover
   (`host-identity-signal-during-gh-start`).
3. `linkcheck-tag-scanner` (lowers linkcheck's peak memory).
4. Then the Ghostty items (`ghostty-test-message`,
   `ghostty-allowlist-breadth`, `gotham-autosuggest-contrast`).
5. Then the packages and stack-docs items (`packages-test-filter`,
   `stack-condition-api` and the `ghstack-*` items).
6. The `runner-*` and remaining `linkcheck-*` items, as the runner or
   linkcheck are next touched.
7. `handoff-check-gate` when the layout of this directory has settled.

## Open for the operator

Whether the one open commit of `fix/parallel-flakes` gets a PR. It touches
the `security-model` surface "The SSH signing setup", so the PR needs the
maintainer's agreement in an issue. Recommendation: open its PR with the
surface ticked and the agreement issue linked, or drop the branch.

## In flight

- Branch `fix/parallel-flakes`: one commit left, 1e04ebd (end gh when a
  signal lands while it starts). See the pending item above.

Branch and PR state is not recorded here: measure it with
`~/.sbx-kit/claude-home/bin/handoff_state.py`.
