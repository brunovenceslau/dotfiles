# gh-stack v0.2.1 pin and the allowed-signers lint deferral

Two PRs merged together as one GitHub stack on 2026-10-13, as acd7cf1: #70
(chore(packages): pin gh-stack v0.2.1, and say where GitHub reports a stack),
and #71 (docs: defer a one-principal lint for the allowed-signers file).

#70 bumps `packages/gh-extensions.txt` from v0.1.0 to v0.2.1 and rewords the
stack condition and the signing note in docs/stacked-prs.md and CLAUDE.md. A
local end-to-end run of v0.2.1 and an attestation check of the linux-amd64
asset backed the bump. #71 adds one row to the Deferred decisions of
docs/development.md. Gates: three ship rounds (the ship gate is the pre-merge
review by reviewer and security personas), local-ci on the stack top, hosted
CI green. Left open: the `ghstack-*` items and `packages-test-filter` in
pending/.

Lessons from the effort (PRs #64 to #71):

1. Run local-ci on the stacked top, not only in each worktree. A gap between
   two PRs (a symlinked `TMPDIR` meeting a symlink refusal) showed up only on
   the combined tree.
2. Item numbers carried across PR bodies were never written to a file and had
   to be rebuilt from older PRs. One file of pending items with stable labels
   closes that; this directory is it.
3. Quoting placeholders alone did not stop branch-name injection into shell
   text. The fix was to stop pasting names into shell text, and only an
   end-to-end matrix of shells and contexts proved it.
