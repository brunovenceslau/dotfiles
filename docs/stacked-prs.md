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

## The rule: every PR targets `main`, with one exception

By default every pull request in a stack opens against `main`. The dependency
is stated in the PR body ("stacked on #N, review only the last K commits"),
never in `--base`.

The one exception is a **GitHub stack**: each child PR is based on its parent's
branch and GitHub links the PRs into a native stack (the `gh-stack` extension
does this; `gh stack --help` and <https://gh.io/stacks> document it). It is
allowed only while both conditions hold:

1. `gh stack view` shows a stack number for the stack on GitHub. Linking is
   best-effort, so a stack that is not linked remotely falls back to the
   default: retarget every PR to `main`.
2. The maintainer merges it as a stack: `gh stack merge --merge`, or the stacked
   PR's Merge button with **Create a merge commit**. That is one atomic
   operation, and GitHub retargets the remaining PRs as part of it.

Squash and rebase merges are excluded, because each makes new commits on the
server and loses the signed commits (see
[Merges use a merge commit](../CONTRIBUTING.md#pull-requests)). So is any other
merge, for example `gh pr merge` on the bottom PR: it deletes the parent's
branch without the atomic retarget, which is the race described next. For a
headless run, `gh stack merge --merge --yes` skips the confirmation prompt
(`--yes` merges the whole stack, or everything up to a given PR number).

### Why not chain the bases

A `--base <branch>` pull request is coupled to that branch's lifetime. With
`delete_branch_on_merge` on, merging the parent deletes its head branch, and
GitHub's automatic retarget of the child races that deletion. The child can lose
that race and be **closed**, which is unrecoverable: a closed PR cannot be
retargeted (`gh pr edit --base` silently does nothing) and cannot be reopened
(`gh pr reopen` fails). The review thread is lost and the only way forward is a
replacement PR. The atomic stack merge removes the race, which is why it is the
only merge the exception admits.

There is one rejected alternative: keep base-chaining and its native stack
rendering by turning `delete_branch_on_merge` **off**, so a child's base
survives its parent's merge. The price is stale parent branches to prune after
the whole stack lands. Adopt it only as a deliberate repository-setting change.
Until then, the rule above stands.

### What targeting `main` costs

Two things. GitHub does not render a native stack, and each PR's diff is
cumulative, showing the commits of the PRs below it. The "review only the last K
commits" note in the body mitigates the second, because GitHub's per-commit view
honors it. That cost is worth paying to make the unrecoverable close impossible
whenever the stack merge conditions above do not hold.

## The workflow

One change is one branch off `main`. Each entry earns the full workflow.

1. Branch off `main`, or off the previous entry's HEAD when it genuinely builds
   on it. On the default path the commits stack even though the PR base stays
   `main`.
2. Write a failing test, then the implementation, then get the gates green.
3. Review the final bytes before opening the PR. A reviewer's read covers every
   branch below the one under review, so batch parent amendments until the
   child's review is done, or accept that the reviewer re-reads.
4. `gh pr create --base main`, with the dependency stated in the body. For a
   GitHub stack, `gh stack submit` opens the chain instead, and `gh stack view`
   must then show the stack number before the exception applies.
5. Repeat for the next change.

Keep stacks shallow and land the bottom fast. Every change requested on a parent
forces a rebase, a full `local-ci` run and a re-ship on each child above it. A
deep stack multiplies that cost, and whole rounds can go to rebase mechanics
alone.

## Re-syncing after a merge

Land bottom-up. What happens next depends on how the bottom landed.

### After any merge other than a stack merge

Every PR targets `main`, so rebase each surviving branch onto the new `main`,
dropping the merged parent's commits:

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

### After a stack merge

GitHub rebases the surviving PRs server-side, so the recipe above does not
apply to them. Their commits are rewritten on the server, so check each
survivor before trusting it. GitHub's "verified" flag is not enough on its own:
it is also true for a commit that GitHub signs with its own key, which is what a
server-side rewrite can produce. The check below looks at the SIGNER, and a
survivor commit signed by GitHub's own key counts as unsigned and is re-signed
by step 5.

1. `git fetch --all --prune`.
2. Right after that fetch, and before any push moves the tracking ref, record
   each survivor's old tip with `git rev-parse origin/<branch>`. Run no other
   fetch in between: the `--force-with-lease=<branch>:<old-tip>` pushes below
   rely on that value.
3. Verify every survivor commit, not only the tip (`<baseRefName>` is the
   survivor's base branch, step 5). The primary check is local: git must verify
   the signature against the allowed-signers file (`gpg.ssh.allowedSignersFile`,
   see [the signing key page](signing-key.md)) and the signer must be the
   maintainer. Keep exactly ONE principal per allowed-signers line, the
   maintainer's email: `%GS` is the first principal on the matching line, so a
   line shared with another principal can pass for a key that is not the
   maintainer's alone. GitHub's flag is a second signal that must print `true`.
   The snippet stops at the first bad commit and exits nonzero. Each of these
   is a failure, not a pass: a ref git cannot resolve (the base already pruned
   by step 1's `--prune`, for one), a failing `git rev-list`, an empty range, a
   gh error, or an empty or other answer from gh.

   The block is POSIX sh, run in a child shell by `sh -eu`: a bare `set -e`
   is ignored when the code runs as the condition of an `if`, `&&` or `||`,
   and an `exit` here cannot close your own shell. So every step that can
   fail carries its own `|| { ...; exit 1; }`, and it fails closed in every
   context, zsh included. Fill in the three placeholders on the first lines:

   ```sh
   sh -eu <<'EOF'
   base_ref=<baseRefName>            # fill in: the survivor's base branch
   branch=<branch>                   # fill in: the survivor's branch
   repo=<owner>/<repo>               # fill in: the GitHub repository
   me=$(git config user.email) ||
     { echo "git user.email is not set" >&2; exit 1; }
   base=$(git rev-parse --verify --quiet "origin/$base_ref^{commit}") ||
     { echo "cannot resolve origin/$base_ref" >&2; exit 1; }
   tip=$(git rev-parse --verify --quiet "origin/$branch^{commit}") ||
     { echo "cannot resolve origin/$branch" >&2; exit 1; }
   list=$(git rev-list "$base..$tip") ||
     { echo "git rev-list failed for $base..$tip" >&2; exit 1; }
   [ -n "$list" ] || { echo "empty range $base..$tip" >&2; exit 1; }
   for c in $list; do
     st=$(git log -1 '--format=%G?' "$c") ||
       { echo "git log failed for $c" >&2; exit 1; }
     who=$(git log -1 '--format=%GS' "$c") ||
       { echo "git log failed for $c" >&2; exit 1; }
     if [ "$st" != G ] || [ "$who" != "$me" ]; then
       echo "not signed by $me: $c ($st $who)" >&2; exit 1
     fi
     ok=$(gh api "repos/$repo/commits/$c" \
       --jq .commit.verification.verified) || ok=
     [ "$ok" = true ] || { echo "not verified by GitHub: $c" >&2; exit 1; }
   done
   EOF
   ```

   Want: exit status 0.

4. Before each rebase, refuse to continue if the local branch holds commits
   that are not on the remote, because `git checkout -B` discards them. Then
   check the branch out at the remote tip. Steps 5 and 6 run only if this
   block exits 0. Run them as separate commands after it, not chained: step 5
   or step 6 applies to a given survivor, never both.

   ```sh
   sh -eu <<'EOF'
   branch=<branch>                   # fill in: the survivor's branch
   git rev-parse --verify --quiet "origin/$branch^{commit}" >/dev/null ||
     { echo "cannot resolve origin/$branch" >&2; exit 1; }
   if git show-ref --verify --quiet "refs/heads/$branch"; then
     ahead=$(git rev-list "origin/$branch..$branch") ||
       { echo "git rev-list failed for $branch" >&2; exit 1; }
     [ -z "$ahead" ] ||
       { echo "$branch has unpushed commits: stop and decide" >&2; exit 1; }
   fi
   git checkout -B "$branch" "origin/$branch"
   EOF
   ```

   Want: exit status 0.

5. Work bottom-up. The lowest survivor whose commits fail verification is
   re-signed onto its own `baseRefName` (`main` for the lowest survivor, the
   lower survivor's branch above it). A plain rebase would say "up to date" and
   sign nothing, hence `--force-rebase`:

   ```sh
   git -c commit.gpgsign=true rebase --force-rebase origin/<baseRefName> <branch>
   git push --force-with-lease=<branch>:<old-tip> origin <branch>
   ```

6. Each higher survivor is replayed onto the rewritten branch below it, cutting
   at that branch's old tip:

   ```sh
   git -c commit.gpgsign=true rebase --onto origin/<lower-branch> <old-lower-tip> <branch>
   git push --force-with-lease=<branch>:<old-tip> origin <branch>
   ```

   A survivor needs no rebase only when no survivor below it was rewritten.
7. Re-run the step 3 block on every survivor (set its three placeholders for
   each one).

`gh stack sync` and `gh stack rebase` also cascade-rebase a stack, but they are
not part of this recipe: it needs the explicit signed commands above, and the
verification, to stay auditable.

### Signing must survive the rebase

`git rebase` rewrites commits, which strips their signatures. With
`commit.gpgsign` off, a plain `git rebase` leaves the replayed commits unsigned
and GitHub silently drops the Verified badge. The tracked config turns it on,
but only where git reads that config, and a host may opt out, so always pass
`-c commit.gpgsign=true` explicitly.

## Retargeting a non-compliant PR

If an open PR is still based on a branch that just landed, and the stack merge
conditions did not hold for that landing, retarget it **first**, while it is
still open, and only then rebase:

```sh
gh pr edit <n> --base main
```

The rebase fixes the branch contents. Only the retarget removes the base
coupling that the branch's deletion turns into an unrecoverable close.

## `gh stack` and this workflow

`gh-stack` is installed by the packages phase, pinned to a reviewed release tag
in `packages/gh-extensions.txt`. If it is missing, install it with the tag from
that manifest:

```sh
gh extension install --pin <tag> -- github/gh-stack
gh stack view
```

`gh stack view` shows the chain and whether GitHub knows it as a stack. Use
`gh stack submit` or `gh stack link` only for a stack that will be merged as a
stack: both base each PR on the branch below it, which is the base-chaining the
default rule rejects. For a stack that will not be, open the PRs with
`gh pr create --base main` instead.

## Requirements

- All branches live in this repository. Cross-fork stacks are not supported.
- Branch protection and CI run on every PR in the stack, so a red leg anywhere
  blocks that PR. That is why each entry ships green before the next lands.
