<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# CLAUDE.md

Guidance for Claude Code in this repository.

This file is loaded into context on every session, so it holds only what changes
what you do. The detail behind these rules lives in `docs/` and in
`.claude/rules/`, and is read only when it is needed.

## What this repo is

A self-built zsh dotfiles framework for macOS, Apple Silicon and Intel.

`~/.config/dotfiles` is the install location and the dev workspace at the same
time, by design of the single-repo model. A second checkout under
`~/src/github.com/brunovenceslau/dotfiles` is equally valid. Never edit
both at once.

There is no separate specification. The code and its comments are the spec.

## Always

- Write everything in the repo in **English**: code, comments, docs, commit
  messages, PR text.
- Make each comment explain the CONSTRAINT ("MUST load after...", "no fork
  here", "the first .bak is the pristine pre-framework file"), never the
  obvious. Someone asking why a line is the way it is should find the answer
  beside it.
- Put everything under XDG paths. `~/.zshenv` is the only file the framework
  creates in `$HOME`.
- Run `make lint` before every commit and `make local-ci STRICT=1` before every
  push. Sign every commit.
- Treat a local green as unproven until you check it. Tool-availability skips in
  `tests/` exit 0 even under `STRICT=1`, so a pass proves what ran, not what was
  covered. When a suite matters, confirm it did not skip.
- Open every PR against `main`, stacked or not, and state the dependency in the
  body ("stacked on #N, review only the last K commits"). A `--base <branch>`
  child races its parent's branch deletion on merge and can lose, which CLOSES
  it: a closed PR can be neither retargeted nor reopened. See
  [docs/stacked-prs.md](docs/stacked-prs.md).

## Ask the user first

- Any change to the security model. Not an exhaustive list: SHA-pinned plugin
  submodules and their static loader, the SSH signing setup, `fsckObjects`
  forced on every fetch (the detached update sentinel included), the ambient
  git-config scrubbing on the upgrade path (`vgit` in `install.sh`), and the
  neutralized fast-syntax-highlighting runtime download.
- Adding a submodule or any binary dependency.
- Changing a link convention.
- Running a remote interactive installer, such as the Homebrew bootstrap.

## Never

- Write anything outside `~/.config/dotfiles` without warning the user first.
- Commit a secret.
- Put a synchronous subprocess or a network call on the zsh startup path.
- Use bash 4 syntax in `install.sh` or `lib/`: no `declare -A`/`typeset -A`, no
  `mapfile`/`readarray`, no `${var,,}`. macOS's `/bin/bash` is 3.2 and runs the
  installer. `bin/` is exempt.
- Hardcode a Homebrew prefix. `/opt/homebrew` (Apple Silicon) and `/usr/local`
  (Intel) are told apart by directory existence, never by a `brew shellenv`
  fork. Arch checks go through `is-arm64`/`is-amd64` in `lib/os.sh`.
- Overwrite a user file without backing it up to `*.bak` first.
- Commit a `.local` file, or let an uninstall remove one. They are the user's
  machine-local layer: untracked, and `--purge` leaves them alone.
- Delete a subcommand from `install.sh`. The name is a cross-version ABI: the
  PREVIOUS release's installer invokes it on the NEW tree. Retire an arm by
  making it a no-op, the way `reseed-settings` does.
- Put gate logic in CI YAML. A gate lands as a `make` target wired into
  `make local-ci` first, and only then does CI run it.

## Where the detail lives

None of these are loaded for you. Read one when you need it.

| Question | Page |
| --- | --- |
| What does each gate prove? What does `STRICT=1` change? How is CI wired? | [docs/development.md](docs/development.md) |
| How does the link engine pick a destination, and what does the manifest record? | [docs/architecture.md#how-linking-works](docs/architecture.md#how-linking-works) |
| How does the `.local` layer work, and which surfaces have one? | [docs/architecture.md#the-local-layer](docs/architecture.md#the-local-layer), [docs/shell-reference.md#local-files](docs/shell-reference.md#local-files) |
| How are the zsh plugins pinned, and what has to be re-checked on a bump? | [docs/architecture.md#plugins-and-the-supply-chain](docs/architecture.md#plugins-and-the-supply-chain) |
| What happens during `dotfiles-upgrade`? | [docs/architecture.md#the-upgrade-path](docs/architecture.md#the-upgrade-path) |
| Why is the prompt cached instead of evaluated at startup? | [docs/architecture.md#the-prompt-and-z-are-cached-not-evaluated](docs/architecture.md#the-prompt-and-z-are-cached-not-evaluated) |
| How do Apple Silicon and Intel differ, and where do arch differences live? | [docs/architecture.md#platform-differences](docs/architecture.md#platform-differences) |
| What does this subcommand, command, alias, or variable do? | [docs/shell-reference.md](docs/shell-reference.md) |
| The framework printed a message. What does it mean? | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Anything else | [docs/README.md](docs/README.md) |

<!--
Maintainer note. Block HTML comments are stripped before this file is injected
into context, so this costs no tokens.

Area rules live in .claude/rules/*.md, each scoped with `paths:` frontmatter.

  shell-bash.md   install.sh, lib/**, bin/**, tests/**
  shell-zsh.md    zsh/**
  docs.md         docs/**, README.md

Measured on Claude Code 2.1.272, with a rule whose body was a behaviour marker
and a control run that touched nothing:

  no file touched            rule NOT applied
  Read tool on a match       rule applied
  Edit tool on a match       rule applied
  bash `>>` on the same path rule NOT applied

So the trigger is a FILE TOOL reaching a matching path. A shell command that
edits the same file (sed -i, a heredoc, >>) does not trigger it. That matters
here: an agent told to prefer bash for file edits can work the whole session
inside zsh/ and never load shell-zsh.md.

A rule that must hold BEFORE any matching file is touched cannot live in
.claude/rules/ at all, because nothing would have triggered it yet. Such rules
stay inline above, and the rules file carries only the elaboration.
-->
