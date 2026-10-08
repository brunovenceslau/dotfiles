<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# dotfiles

[![CI](https://github.com/brunovenceslau/dotfiles/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/brunovenceslau/dotfiles/actions/workflows/ci.yml)
[![REUSE status](https://api.reuse.software/badge/github.com/brunovenceslau/dotfiles)](https://api.reuse.software/info/github.com/brunovenceslau/dotfiles)

A zsh configuration framework for macOS, on Apple Silicon and Intel. It installs
by symlinking this repository into your home directory, keeps `$HOME` clean by
following the XDG base directory layout, and carries no plugin manager and no
runtime downloads.

The repository is the install. You clone it to `~/.config/dotfiles`, run
`./install.sh`, and that same clone is what every shell loads, so editing it is
the way you change your setup. It is a starting point you own, not a product
you configure: read [Who this is for](#who-this-is-for) before you clone.

## Quick start

On a Mac that already has `git` (cloning over HTTPS needs no credentials):

```sh
git clone --recurse-submodules https://github.com/brunovenceslau/dotfiles.git ~/.config/dotfiles
cd ~/.config/dotfiles
./install.sh && exec zsh
```

Then give this machine its own git identity. If your
[allowed-signers file](docs/signing-key.md#list-a-hosts-key-in-the-allowed-signers-file)
lists the key in this machine's ssh-agent, the installer derives it:

```sh
./install.sh identity --name "Your Name"
```

Otherwise set it by hand, with this machine's signing key:

```sh
git config --file ~/.config/git/config.local user.name  "Your Name"
git config --file ~/.config/git/config.local user.email "you@example.com"
git config --file ~/.config/git/config.local user.signingkey ~/.ssh/id_signing.pub
```

The tracked git config turns commit signing on, so until a signing key is
set every commit fails. A machine that must commit without one opts out, as
in [keep a host from signing](docs/signing-key.md#keep-a-host-from-signing).
It also sets `user.useConfigOnly`, so git never invents a name or an email:
until both are set, every commit fails too, even on a machine that opted
out. The installer writes the email, but only `--name` sets the name. The
`GIT_AUTHOR_*` and `GIT_COMMITTER_*` environment variables still supply an
identity, as they always do.

Bare Mac, no `git` yet? Start with
[Provision a new mac host](docs/new-mac-host.md). Before you trust `install.sh`
with your home directory, the [Security model](#security-model) lists what it
does and does not protect.

## Contents

- [Quick start](#quick-start)
- [Who this is for](#who-this-is-for)
- [What you get](#what-you-get)
- [Requirements](#requirements)
- [Install](#install)
  - [Clone and link](#clone-and-link)
  - [Set your git identity](#set-your-git-identity)
  - [Install the packages (optional)](#install-the-packages-optional)
  - [Check that the install worked](#check-that-the-install-worked)
- [Everyday commands](#everyday-commands)
- [Updating](#updating)
  - [The background update check](#the-background-update-check)
- [Uninstalling](#uninstalling)
  - [What uninstall leaves behind](#what-uninstall-leaves-behind)
- [Security model](#security-model)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [Credits](#credits)
- [Licence](#licence)

## Who this is for

**Use it if** you run macOS, you want your shell configuration to be one git
repository with an exact uninstall, and you are willing to read the code and
adapt it.

**Do not use it if** any of the following is true.

- **You want a general-purpose dotfiles manager.** This is one person's live
  configuration, published as a framework. It is not a tool for managing
  someone else's dotfiles, and it makes no attempt to be neutral about which
  programs you use or how they are configured.
- **You are not on macOS.** macOS is the only supported platform, and CI covers
  only macOS runners (`.github/workflows/ci.yml`). `install.sh` and `lib/`
  target bash 3.2, the version macOS ships. No link rule or install step
  branches on the OS, so on Linux the installer still creates the links, but the
  package manifest, the Homebrew prefix detection and the terminal configuration
  do not apply there.
- **You want a stable configuration surface.** The public interface is not
  frozen. Subcommand names are kept for compatibility, but paths, variables and
  defaults can change between releases.
- **You want the upstream to adopt your preferences.** Pull requests that fix a
  defect, close a gap in the gates, or improve the documentation are welcome.
  Requests to change the maintainer's own configuration choices are not.

## What you get

- **One framework file in `$HOME`.** Only `~/.zshenv`. Everything else lives
  under `~/.config`, `~/.cache` and `~/.local`.
- **A fork-free interactive startup path.** Nothing on the path to your first
  prompt runs a subprocess or waits on the network, and `make forkgate` proves
  it by measuring what an interactive shell actually invokes. The one exception
  is [the background update check](#the-background-update-check).
- **Pinned plugins, no plugin manager.** Three zsh plugins are git submodules
  pinned to exact commits, loaded by a static loader in the zshrc.
- **An exact uninstall.** Every symlink the installer creates is recorded in a
  manifest, every file it replaces is backed up first, and uninstall reverses
  both. CI verifies it with a before and after diff of a scratch home on every
  run. The one file left on purpose is described in
  [What uninstall leaves behind](#what-uninstall-leaves-behind).
- **A per-host `.local` layer.** The shell, git, terminal, tmux and package
  surfaces each load an untracked `.local` companion, so two machines differ
  without forking the repository. The
  [shell reference](docs/shell-reference.md#local-files) lists every one.
- **One tool on your `PATH`.** The installer links `bin/tmux-status` (the tmux
  status-line helper) into `~/.local/bin`. The repository's quality gates stay
  in `bin/` and run through `make`; they are never linked.

## Requirements

| Requirement | Why |
| --- | --- |
| macOS on arm64 or x86_64 | The only supported platform. |
| zsh | The login shell. macOS ships a recent one, and the Brewfile deliberately does not install a second copy. |
| git | Clone plus submodules. Xcode Command Line Tools provide it (`xcode-select --install`). |
| Homebrew | Only for `./install.sh packages`. Linking works without it. |

Run everything as your own user. `install.sh` refuses to run as root, for every
subcommand, and never needs `sudo`.

## Install

The [Quick start](#quick-start) is the whole install. This section explains each
step and what to do when one does not go as planned.

### Clone and link

The three commands in the [Quick start](#quick-start) clone the repository and
run the installer.

- `--recurse-submodules` matters: the zsh plugins are pinned submodules, and a
  non-recursive clone leaves them empty until the next `./install.sh` repairs
  them.
- The installer is idempotent, so a re-run changes nothing.
- It links whole directories for alacritty, ghostty, lazygit, nvim, starship and
  tmux into `~/.config`. If one of those already exists as a real directory, the
  installer refuses to replace it, places every other link, caches the shell
  integrations, skips the plugin submodule step, and exits 1. Move the directory
  aside and re-run `./install.sh`; see
  [Install refuses a link](docs/troubleshooting.md#install-refuses-a-link).

### Set your git identity

The tracked git config carries no identity or signing key, so every machine sets
its own in the untracked `~/.config/git/config.local` (the
[Quick start](#quick-start) shows both ways: `./install.sh identity` or
`git config` lines), and nothing commits as the maintainer.

The tracked git config turns commit signing on, so until this machine has a
signing key, git refuses every commit, and the installer says so. To set the
key up, see
[Provision a new mac host](docs/new-mac-host.md#5-set-identity-and-signing).
Signing is mandatory only where git reads the tracked config; the known
paths that still produce an unsigned commit are in
[where commit signing is mandatory](docs/shell-reference.md#where-commit-signing-is-mandatory).
Rotating, revoking and opting a host out are in
[Manage this host's signing key](docs/signing-key.md).

### Install the packages (optional)

The package set is Homebrew formulae, casks and pinned `gh` extensions. It is a
separate subcommand, so linking never depends on Homebrew:

```sh
./install.sh packages
```

Per-host additions go in the untracked `packages/Brewfile.local` and
`packages/gh-extensions.local.txt`.

### Check that the install worked

- `zsh -i -c exit` exits 0 with nothing on stderr.
- `readlink ~/.zshenv` points into `~/.config/dotfiles`.
- `git -C ~ config --show-origin --get user.email` returns the address you
  set, from `~/.config/git/config.local`.
- `./install.sh doctor` prints nothing.

For a bare machine, [Provision a new mac host](docs/new-mac-host.md) adds the
prerequisites, the signing key, and the cleanup of a legacy `~/.gitconfig`.

## Everyday commands

| Command | What it does |
| --- | --- |
| `./install.sh` | Create the state and cache directories, copy a pre-XDG `~/.zsh_history` over, create every link, initialize missing plugin submodules, cache the shell integrations, and run the automatic identity step. Idempotent. |
| `./install.sh link` | Recreate the links and the manifest, refresh the cached shell integrations, and run the automatic identity step. This is what an upgrade re-runs. |
| `./install.sh identity [--name "Full Name"] [--rotate]` | Set this machine's git identity and signing key from its allowed-signers file and ssh-agent; `--rotate` replaces a key that no longer verifies. |
| `./install.sh doctor [--verbose]` | Check the identity, the signing key and the tools they need, without writing anything. Prints only problems, and exits 1 when it finds one. |
| `./install.sh packages` | `brew bundle` over `packages/Brewfile`, then the pinned `gh` extensions. |
| `./install.sh --help` | Print the usage (`-h` and `help` work too). |
| `dotfiles-upgrade` | Fetch, fast-forward merge, update submodules, relink, recompile. Same as `./install.sh upgrade`. |
| `dotfiles-uninstall [--purge]` | Remove the framework's links and restore backups. `--purge` also deletes generated cache and state, **including your shell history**. Same as `./install.sh uninstall [--purge]`. |
| `reload` | Re-source `$ZDOTDIR/.zshrc` in the current shell. |

`dotfiles-upgrade` and `dotfiles-uninstall` are zsh functions defined in
`zsh/functions.zsh`, so they exist only in an interactive shell that loaded this
framework. From a script, call `~/.config/dotfiles/install.sh upgrade` directly.

For the full surface (every `install.sh` subcommand and exit code, aliases,
helper functions, environment variables, every `.local` file), see the
[shell reference](docs/shell-reference.md).

## Updating

```sh
dotfiles-upgrade
```

- The merge is fast-forward only, so a diverged or rewound history is refused
  rather than reset to.
- The command refuses to run while tracked files are modified, so commit or
  stash first. Untracked `.local` files never block it.
- It trusts whatever the remote you cloned from serves; see
  [Security model](#security-model).
- It runs the automatic identity step: a machine that does not sign yet gets
  its identity as soon as its allowed-signers file and ssh-agent agree on a
  key, and a machine that signs hears in one line when its key no longer
  verifies. See [Manage this host's signing key](docs/signing-key.md).

[The upgrade path](docs/architecture.md#the-upgrade-path) explains every step.

### The background update check

A shell start launches a detached, non-blocking `git fetch` of this repository
at most once per cadence window, 3 days by default, and notifies you on the next
prompt when updates are available. It is the only network access a shell start
can cause.

- Change the cadence with `DOTFILES_UPDATE_CADENCE_DAYS`.
- Turn the check off by setting `DOTFILES_UPDATE_DISABLE` to any non-empty value
  (`DOTFILES_UPDATE_DISABLE=1`), in the environment or in
  `$ZDOTDIR/.zshrc.local`.

[How it works](docs/architecture.md#the-one-sanctioned-background-spawn), and
[what to do when a notice will not go away](docs/troubleshooting.md#update-notices-do-not-go-away).

## Uninstalling

```sh
dotfiles-uninstall            # remove links, restore backups
dotfiles-uninstall --purge    # also delete generated cache and state
```

Uninstall is driven by the manifest at `$XDG_STATE_HOME/dotfiles/manifest`. It
removes only the links the manifest lists, and only while they are still the
framework's. It restores each `*.bak` byte for byte, then removes any directory
those removals left empty, up to but never including `$HOME`. It never removes
your untracked `.local` files. How a link is judged to be the framework's,
including links another checkout made, is in
[The manifest closes the loop](docs/architecture.md#the-manifest-closes-the-loop).

> **Warning:** `--purge` also deletes `$XDG_CACHE_HOME/zsh`,
> `$XDG_STATE_HOME/dotfiles` and `$XDG_STATE_HOME/zsh`, which holds your shell
> history (`$XDG_STATE_HOME/zsh/history`, by default
> `~/.local/state/zsh/history`). Copy that file somewhere else first if you want
> to keep it.

To reinstall and keep your history, uninstall without `--purge`:

```sh
dotfiles-uninstall && ./install.sh && exec zsh
```

### What uninstall leaves behind

Both forms leave `~/.config/git/config` in place. The installer wrote it as a
real file that includes the tracked git config, and it is where
`git config --global` writes, so it may hold settings you added. Once the
repository is gone, delete it by hand if you no longer want it:

```sh
rm ~/.config/git/config
```

For anything else that survived, see
[Uninstall left something behind](docs/troubleshooting.md#uninstall-left-something-behind).

## Security model

You are being asked to run a shell script that links a repository into your home
directory and then loads it on every shell start. These properties are what make
that reviewable:

- **No plugin manager and no runtime download.** The three zsh plugins are
  submodules pinned to exact commits, loaded by a static loader, and the
  fast-syntax-highlighting theme download is neutralized, so a pinned commit
  cannot be bypassed at source time.
- **Object checking on every fetch after install.** `transfer`, `fetch` and
  `receive.fsckObjects` are on once the framework's git config is linked, and
  the upgrade path re-asserts them after scrubbing ambient git config, so a
  hostile global config cannot turn them off. The first `git clone` runs before
  that config exists, so it is checked only by your own git settings;
  `install.sh` forces object checking for the plugin submodules it fetches.
- **Fast-forward-only upgrades.** A rewound or diverged remote history is
  refused rather than checked out.
- **A fork-free startup.** Nothing on the interactive startup path runs a
  subprocess or waits on the network, except
  [the background update check](#the-background-update-check).
- **No root.** `install.sh` refuses to run as root for every subcommand and
  never needs `sudo`.
- **Backups before overwrites.** No user file is overwritten without a `.bak`
  copy first, and uninstall restores it.
- **A signing key only by exact agreement.** The identity step chooses or
  writes a signing key only when the allowed-signers file and the ssh-agent
  agree on exactly that key. It writes nothing automatically in an SSH
  session, and never overwrites a value already set, except `--rotate`,
  which replaces only a signing key that no longer verifies.
- **Two secret scanners.** Two independent scanners run as gates over the tree
  in `make local-ci` and in CI on every push to `main` and every pull request.

None of this verifies signatures on what you fetch. `dotfiles-upgrade` is a
fetch plus a fast-forward merge, and it trusts whatever the remote you cloned
from serves. Read the diff before you upgrade if that matters to you.

Each property, and the file or test that enforces it, is listed in
[Security properties and where they are enforced](docs/architecture.md#security-properties-and-where-they-are-enforced).

To report a vulnerability, use the private advisory form linked from
[SECURITY.md](SECURITY.md). Never a public issue.

## Documentation

| Page | Read it when |
| --- | --- |
| [Architecture](docs/architecture.md) | You want to know how the framework works and why it is built this way. |
| [Shell reference](docs/shell-reference.md) | You need the exact commands, aliases, variables and config files. |
| [Provision a new mac host](docs/new-mac-host.md) | You are setting up a machine from nothing. |
| [Manage this host's signing key](docs/signing-key.md) | You need to check, rotate or revoke a machine's signing key, or keep a machine from signing. |
| [Troubleshooting](docs/troubleshooting.md) | Something is broken and you want the symptom, cause and fix. |
| [Backup and restore](docs/backup-restore.md) | You are setting up or using the restic and rclone backups. |
| [Development](docs/development.md) | You are changing the repository and need the quality gates. |

[docs/README.md](docs/README.md) maps every page to its reader.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. It covers
the toolchain, the commit and signing rules, and the surfaces that need a
maintainer decision before the code is written. In short: everything in the
repository (code, comments, documentation, commit messages) is written in
English, commits are SSH-signed, `make lint` must pass before every commit and
`make local-ci STRICT=1` before every push. The gates and what each one proves
are in [development](docs/development.md). Participation is covered by the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Credits

The framework began as a port of a
[prezto](https://github.com/sorin-ionescu/prezto) setup, and two blocks of
prezto's code are still in it: the `ls` listing aliases in `zsh/aliases.zsh` and
the compsys styling in `zsh/zshrc`. The `$LS_COLORS` palette is the GNU
coreutils `dircolors` database, and the Neovim bootstrap is
[lazy.nvim](https://github.com/folke/lazy.nvim)'s own installation recipe.

Each of those blocks is bracketed in place by `SPDX-SnippetBegin` and
`SPDX-SnippetEnd` and repeats its licence there.
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) lists the upstreams, the
commit each claim was measured against, the licence, and what was taken.

## Licence

GPL-3.0-or-later. The full text is in [COPYING](COPYING), and every file states
its own copyright and licence, so the tree is
[REUSE 3.3](https://reuse.software/spec-3.3/) compliant. `make reuse` checks
it, and `make local-ci` runs that check before every push.
