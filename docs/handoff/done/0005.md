# Parallel-runner flakes fixed, Intel CI made best effort

Five PRs merged on 2026-10-17. PR #74 (handoff notes moved into
docs/handoff) failed hosted CI on two flakes already seen on main on
2026-10-13 (run 38398695919); it merged after rebases, and main CI after it
(90ceb7c, run 39011944581) passed both legs.

- #75 (fix(test): build the quadratic mutant out of the gate's own scan),
  commit 2fb8f6a of `fix/parallel-flakes`, cherry-picked alone. Cause: the
  mutant's quadratic term was a counting loop whose ratio depended on the
  platform, under 23x on macOS arm64. Gates: `make lint` and `make local-ci
  STRICT=1` green locally (Linux arm64); code-reviewer (sonnet) no blocking
  findings; hosted CI green on both legs.
- #76 (fix(test): stop git's auto repack from racing the fixture clones),
  commit eeccb6c, cherry-picked alone. Cause: git 2.54's geometric auto
  maintenance repacked the fixture ("the zsh tree is not a loose object" on
  macOS Intel). Gates: local CI green; `host_identity_test` passed 3 times
  locally on git 2.53, so the original failure was not reproduced here;
  code-reviewer no blocking findings; hosted CI green on both legs.
- #77 (fix(test): give the quadratic mutant its own 8x CPU floor). After #75
  the mutant's true ratio (about 53x) is past KILL_RATIO (40), so its 8x run
  was held only by the 2 s floor, and on macOS Intel it died of SIGXCPU (exit
  152, run 39005605868). Reproduced locally with a 20x heavier mutant (exit
  152 at floor 2, ratio caught at floor 20). `growth_hostile.py` and
  `hostile_growth` take FLOOR as an argument; the real check and the
  exponential mutant keep 2 s, the quadratic mutant gets 20 s. Gates: local
  CI green; code-reviewer no blocking findings, its comment nits applied;
  hosted CI green on both legs (Intel 22m25s).
- #78 (ci: run the Intel leg weekly, make Intel support best effort), merged
  as ed055fd. `ci.yml` gained `workflow_call` with a `legs` input; a push or
  PR runs arm64 only; `.github/workflows/intel.yml` runs the Intel leg on
  Mondays 06:00 UTC and on `workflow_dispatch` by calling `ci.yml`.
  `repo-settings.json` and the live branch protection on main dropped the
  Intel leg's required check (`make repo-settings-check`: 41 ok, 0 drift on
  the PR branch). Gates: local CI green; code-reviewer no blocking
  findings; hosted CI green (arm64); main CI after it (run 39012190107) green
  on arm64. The first manual Intel run on ed055fd (run 39012204606,
  `workflow_dispatch`) passed in about 16 minutes, which also confirms that
  the SHA-pinning Actions setting accepts the local `uses:
  ./.github/workflows/ci.yml` call.

Review notes declined. On #75: a smaller multiplier and an assert on h26's
25001-byte size; #77 fixed the budget instead, and a shrunk h26 fails
loudly. On #78: moving the historical "both CI legs" comments in the
Makefile and two tests; left, since they stay true while both legs exist.

The decision on Intel support is in
decisions/intel-macos-support-is-best-effort.md. One commit of
`fix/parallel-flakes` is still open; see
pending/host-identity-signal-during-gh-start.md.
