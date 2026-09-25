<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Contributing

This page is for someone about to open a pull request. It covers what has to be
true before a change can merge: the gates, the commit rules, and the surfaces
that need a decision before you write the code.

Before you start, read [Who this is for](README.md#who-this-is-for). This is one
person's live configuration published as a framework. A change that fixes a
defect, closes a gap in a gate, or makes the documentation match the code is
welcome. A change that replaces the maintainer's own configuration choices is not,
and will be closed regardless of how well it is written.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Set up the toolchain

The gates need tools the repository does not vendor. The list, the reason for
each one, and the single `brew install` line that covers them are in
[development, Prerequisites](docs/development.md#prerequisites). That section is
held to CI's own tool list by `tests/dev_docs_prereqs_test.sh`, so it cannot
drift from what CI provisions.

## Run the gates the way CI runs them

```sh
make lint                  # before every commit
make local-ci STRICT=1     # before every push
```

`STRICT=1` is what CI sets. Without it, a gate whose tool is missing warns and
exits 0, so a local green can mean the check never ran. With it, the same gate
fails instead.

Even under `STRICT=1`, some suites skip on a tool they cannot find and still
exit 0. A pass proves what ran, not what was covered. If a suite matters to your
change, read its output and confirm it did not skip.

What each target proves is in [development, The gates](docs/development.md#the-gates).

## Write the change

- **Write the failing test first.** Every gate in this repository exists because
  something broke once. A change to behaviour lands with the test that would
  have caught the regression.
- **One change is one branch off `main`.**
- **English everywhere.** Code, comments, documentation, commit messages and
  pull request text.
- **Comments explain the constraint, not the obvious.** "MUST load after the
  compdump is cached" is a comment. "Loop over the files" is not.
- **No em dash anywhere in the repository.** Use a comma, a colon, a
  parenthesis, or a plain `-`.
- **Documentation follows its own standard.** One reader per page, one content
  type per page, no claim that the source does not back up, active voice, and no
  em dash. The full text of the standard is
  [the documentation rules](.claude/rules/docs.md), a file that coding agents
  working in this repository also load.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) for
the subject line, lower case after the colon, 72 characters or fewer:

```
feat(zsh): cache the prompt init instead of evaluating it
```

The types in use are `feat`, `fix`, `docs`, `chore`, `ci`, `test`, `build` and
`refactor`. The scope is optional and lower case. Explain in the body what the
change is and which constraint it keeps, wrapped at 72 columns.

Do not add trailers. No `Co-authored-by`, no `Signed-off-by`, no tool
attribution lines.

## Signed commits are required

Every commit on `main` must carry a valid signature. A branch ruleset on `main`
enforces it on the server, with no bypass actors, so an unsigned commit cannot be
merged and no maintainer can wave it through. The same ruleset blocks force
pushes to `main` and blocks deleting it, so published history cannot be
rewritten or removed. Sign your commits before you push, not after: re-signing
means rewriting the branch.

This project signs with SSH. If you have no signing key yet:

```sh
ssh-keygen -t ed25519 -C "signing key" -f ~/.ssh/id_signing
gh auth refresh -h github.com -s admin:ssh_signing_key   # gh auth login does not grant this scope
gh ssh-key add ~/.ssh/id_signing.pub --type signing --title "signing"
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_signing.pub
git config --global commit.gpgsign true
```

The key must be registered on GitHub with type `signing`. An authentication key
with the same bytes does not count, and GitHub will show the commit as Unverified.
Check the result with `git log --show-signature`, and note that `%G?` reports `N`
for a good SSH signature unless git can see an allowed-signers file. See
`config/git/config.local.example` for that entry.

## Pull requests

- **Every pull request targets `main`.** Including a stacked one. A pull request
  opened with `--base <another branch>` races that branch's deletion when the
  parent merges, and losing the race closes it permanently: a closed pull
  request cannot be retargeted or reopened.
- **State the dependency in the body instead**, as "stacked on #N, review only
  the last K commits". The reasoning and the re-sync commands are in
  [stacked pull requests](docs/stacked-prs.md).
- **Both CI legs must be green**: `local-ci (macos-arm64)` and
  `local-ci (macos-intel)` are required status checks in the `main` ruleset.
- **Merges use a merge commit.** Squash and rebase merging are off, because both
  rewrite your commits: GitHub signs a squash commit with its own key instead of
  yours, and does not sign a rebase-merged commit at all. The head branch is
  deleted automatically after the merge.

### Pull requests from a fork need CI approved by the maintainer

CI runs `make smoke`, which executes the branch's own `install.sh` on a macOS
runner. For a fork that means running a stranger's code, so the repository's
Actions setting requires maintainer approval before any workflow runs on a pull
request from an outside collaborator (anyone without write access). Your checks
stay queued until then. That is expected, not a fault in your branch.

### For the maintainer: changing a repository setting

The ruleset, merge methods and Actions settings this page describes are recorded
in `.github/repo-settings.json`. To change one, update `.github/repo-settings.json`
first, together with every doc that describes the setting, in one pull request.
`tests/repo_settings_test.sh` fails that pull request if a doc and the file
disagree. Once it merges, change the live setting and run
`make repo-settings-check`, which reads the live settings with your `gh` login
and exits non-zero until they match the file. See
[development, Repository settings](docs/development.md#repository-settings).

## Ask before you build any of these

These surfaces are not settled by a good patch. Open an issue first and get an
answer, because a pull request that changes one of them will be closed on the
question rather than on the code.

- **Any change to the security model.** Not an exhaustive list: the SHA-pinned
  plugin submodules and their static loader, the SSH signing setup,
  `fsckObjects` forced on every fetch (the detached update sentinel included),
  the ambient git-config scrubbing on the upgrade path (`vgit` in `install.sh`),
  and the neutralized fast-syntax-highlighting runtime download.
- **Adding a submodule or any binary dependency.**
- **Changing a link convention.**
- **Running a remote interactive installer**, such as the Homebrew bootstrap.

Two more rules sit next to that list and are worth repeating, because breaking
either one breaks a host rather than a test:

- **Never delete a subcommand from `install.sh`.** The name is a cross-version
  interface: the previous release's installer invokes it on the new tree. Retire
  an arm by making it a no-op, the way `reseed-settings` is retired.
- **Never put gate logic in CI YAML.** A gate lands as a `make` target wired
  into `make local-ci` first, and only then does CI call it.

## Reporting a problem instead

- A bug or a request: open an issue with one of the
  [issue forms](https://github.com/brunovenceslau/dotfiles/issues/new/choose).
- A security vulnerability: do not open an issue. Follow
  [SECURITY.md](SECURITY.md).
- Conduct: see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
