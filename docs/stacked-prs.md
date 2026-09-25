<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Stacked pull requests

This page is the maintainer's workflow for branches pushed to this repository.
Outside contributors work from a fork and open one pull request at a time; see
[CONTRIBUTING.md](../CONTRIBUTING.md).

Large changes land as a stack: a chain of small pull requests that build on
each other, each reviewed and gated independently, landed bottom-up. Stacking
keeps every PR small enough to review honestly while a large piece of work keeps
moving.

## The rule: every PR targets `main`

Every pull request in a stack opens against `main`. The dependency is stated in
the PR body ("stacked on #N, review only the last K commits"), never in
`--base`.

### Why not chain the bases

A `--base <branch>` pull request is coupled to that branch's lifetime. With
`delete_branch_on_merge` on, merging the parent deletes its head branch, and
GitHub's automatic retarget of the child races that deletion. The child can lose that race and be **closed**, which is
unrecoverable: a closed PR cannot be retargeted (`gh pr edit --base` silently
does nothing) and cannot be reopened (`gh pr reopen` fails). The review thread is
lost and the only way forward is a replacement PR.

### What targeting `main` costs

Two things. GitHub does not render a native stack, and each PR's diff is
cumulative, showing the commits of the PRs below it. The "review only the last K
commits" note in the body mitigates the second, because GitHub's per-commit view
honors it. That cost is worth paying to make the unrecoverable close impossible.

There is one documented alternative: keep base-chaining and its native stack
rendering by turning `delete_branch_on_merge` **off**, so a child's base survives
its parent's merge. The price is stale parent branches to prune after the whole
stack lands. Adopt it only as a deliberate repository-setting change. Until then,
base is `main`.

## The workflow

One change is one branch off `main`. Each entry earns the full workflow.

1. Branch off `main`, or off the previous entry's HEAD when it genuinely builds
   on it. The commits stack even though the PR base stays `main`.
2. Write a failing test, then the implementation, then get the gates green.
3. Review the final bytes before opening the PR. A reviewer's read covers every
   branch below the one under review, so batch parent amendments until the
   child's review is done, or accept that the reviewer re-reads.
4. `gh pr create --base main`, with the dependency stated in the body.
5. Repeat for the next change.

Keep stacks shallow and land the bottom fast. Every change requested on a parent
forces a rebase, a full `local-ci` run and a re-ship on each child above it. A
deep stack multiplies that cost, and whole rounds can go to rebase mechanics
alone.

## Re-syncing after a merge

Land bottom-up, one PR at a time. After each land, rebase each surviving branch
onto the new `main`, dropping the merged parent's commits:

```sh
git fetch --all --prune
# <old-base-sha> is the pre-merge tip the branch was built on.
git -c commit.gpgsign=true rebase --onto origin/main <old-base-sha> <branch>
git push --force-with-lease origin <branch>
# Verify GitHub considers the new tip verified, not merely that it is signed locally:
gh api "repos/<owner>/<repo>/commits/$(git rev-parse <branch>)" \
  --jq '.commit.verification'      # want: {"verified": true, "reason": "valid"}
```

Use the three-argument form above, and read it carefully: `--onto` takes the
**new** base (`origin/main`), while `<old-base-sha>` is the upstream limit that
decides which commits are replayed. Everything after `<old-base-sha>` is
replayed; everything up to it is dropped, which is how the merged parent's
commits disappear from the child.

A plain `git rebase origin/main` can replay the parent's commits and conflict
when the landed base differs from what the child was built on, which happens
after a review-fix amend or a squash merge. Cutting the replay at the old base
is always correct.

Because the PR base was already `main`, the parent's merge does not touch the
child's pull request. Only the branch contents need the rebase.

### Signing must survive the rebase

`git rebase` rewrites commits, which strips their signatures. With
`commit.gpgsign` off, a plain `git rebase` leaves the replayed commits unsigned
and GitHub silently drops the Verified badge. This framework deliberately omits
`commit.gpgsign` from the tracked config so a keyless clone can commit, so
always pass `-c commit.gpgsign=true` explicitly.

## Retargeting a non-compliant PR

If an open PR is still based on a branch that just landed, retarget it **first**,
while it is still open, and only then rebase:

```sh
gh pr edit <n> --base main
```

The rebase fixes the branch contents. Only the retarget removes the base
coupling that the branch's deletion turns into an unrecoverable close.

## `gh stack` is for viewing only

`gh-stack` is installed by the packages phase, pinned to a reviewed release tag
in `packages/gh-extensions.txt`. If it is missing, install it with the tag from
that manifest:

```sh
gh extension install --pin <tag> -- github/gh-stack
gh stack view
```

Use `gh stack view` to see the chain. Do not use `gh stack submit` or
`gh stack init` here. They set every base to the branch below, which is the
base-chaining this document rejects.

## Requirements

- All branches live in this repository. Cross-fork stacks are not supported.
- Branch protection and CI run on every PR in the stack, so a red leg anywhere
  blocks that PR. That is why each entry ships green before the next lands.
