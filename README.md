<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# dotfiles

[![CI](https://github.com/brunovenceslau/dotfiles/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/brunovenceslau/dotfiles/actions/workflows/ci.yml)
[![REUSE status](https://api.reuse.software/badge/github.com/brunovenceslau/dotfiles)](https://api.reuse.software/info/github.com/brunovenceslau/dotfiles)

A zsh configuration framework for macOS. It installs by symlinking this
repository into your home directory, keeps `$HOME` clean by following the XDG
base directory layout, and carries no plugin manager and no runtime downloads.

The repository is the install. You clone it to `~/.config/dotfiles`, run
`./install.sh`, and that same clone is what every shell loads, so editing it is
the way you change your setup.

## Who this is for

Read this section before cloning. The framework is opinionated, and the
opinions are not hidden.

**Use it if** you run macOS, you want your shell configuration to be one git
repository with an exact uninstall, and you are willing to read the code and
adapt it. It is a starting point you own, not a product you configure.

**Do not use it if** any of the following is true.

- **You want a general-purpose dotfiles manager.** This is one person's live
  configuration, published as a framework. It is not a tool for managing
  someone else's dotfiles, and it makes no attempt to be neutral about which
  programs you use or how they are configured.
- **You are not on macOS.** `install.sh` and `lib/` target bash 3.2, the version
  macOS ships. No link rule or install step branches on the OS, and the CI
  matrix covers only macOS runners (`.github/workflows/ci.yml`). On Linux the installer
  still creates links, but the package manifest, the Homebrew prefix detection
  and the terminal configuration do not apply.
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
  prompt runs a subprocess or waits on the network. `make forkgate` proves it
  by measuring what an interactive shell actually invokes. The one exception is
  the update check: once every 3 days, a shell start launches a detached,
  non-blocking `git fetch` of this repository in the background
  ([how it works, and how to turn it off](docs/architecture.md#the-one-sanctioned-background-spawn)).
- **Pinned plugins.** Three zsh plugins are git submodules pinned to exact
  commits, loaded by a static loader in the zshrc. No plugin manager.
- **An exact uninstall.** Every symlink the installer creates is recorded in a
  manifest. `dotfiles-uninstall --purge` removes only those links, restores the
  files it backed up, and deletes the framework's generated cache and state. It
  leaves one file on purpose: `~/.config/git/config`, a machine-local file that
  `git config --global` writes to (see [Uninstalling](#uninstalling)). CI
  verifies the rest with a before and after diff of a scratch home on every run.
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

## Install

Three lines on a machine that already has `git`. Cloning needs no
authentication: the repository is public and read access is anonymous.

```sh
git clone --recurse-submodules https://github.com/brunovenceslau/dotfiles.git ~/.config/dotfiles
cd ~/.config/dotfiles
./install.sh && exec zsh
```

`--recurse-submodules` matters: the zsh plugins are pinned submodules, and a
non-recursive clone leaves them empty until the next `./install.sh` repairs
them. The installer is idempotent, so a re-run changes nothing.

The installer links whole directories for alacritty, ghostty, lazygit, nvim,
starship and tmux into `~/.config`. If one of those already exists as a real
directory, the installer refuses to replace it, places every other link,
caches the shell integrations, skips the plugin submodule step, and exits 1. Move the directory aside and re-run `./install.sh`; see
[Install refuses a link](docs/troubleshooting.md#install-refuses-a-link).

Then set this machine's git identity in the untracked local config. The tracked
config carries no identity or signing key, so every machine sets its own and
nothing commits as the maintainer:

```sh
git config --file ~/.config/git/config.local user.name  "Your Name"
git config --file ~/.config/git/config.local user.email "you@example.com"
```

Optionally install the package set (Homebrew formulae, casks and pinned `gh`
extensions). This is a separate subcommand, so linking never depends on
Homebrew:

```sh
./install.sh packages
```

**Success looks like this:** `zsh -i -c exit` exits 0 with nothing on stderr,
`readlink ~/.zshenv` points into `~/.config/dotfiles`, and
`git config --get user.email` returns the address you set.

For a bare machine, follow
[Provision a new mac host](docs/new-mac-host.md) instead. It adds the
prerequisites, the signing key, and the cleanup of a legacy `~/.gitconfig`.

## Everyday commands

| Command | What it does |
| --- | --- |
| `./install.sh` | Create state and cache dirs, copy a pre-XDG `~/.zsh_history` over, create every link, initialize missing plugin submodules, and cache the shell integrations. Idempotent. |
| `./install.sh link` | Recreate links and the manifest, then refresh the cached shell integrations. This is what an upgrade re-runs. |
| `./install.sh packages` | `brew bundle` over `packages/Brewfile`, then the pinned `gh` extensions. |
| `dotfiles-upgrade` | Fetch, fast-forward merge, update submodules, relink, recompile. |
| `dotfiles-uninstall [--purge]` | Remove the framework's links and restore backups. `--purge` also deletes generated cache and state, **including your shell history**. |
| `reload` | Re-source `$ZDOTDIR/.zshrc` in the current shell. |

`dotfiles-upgrade` and `dotfiles-uninstall` are zsh functions defined in
`zsh/functions.zsh`, so they exist only in an interactive shell that loaded this
framework. From a script, call `~/.config/dotfiles/install.sh upgrade` directly.

For the full surface (aliases, helper functions, environment variables, every
`.local` file), see the [shell reference](docs/shell-reference.md).

## Updating

```sh
dotfiles-upgrade
```

The merge is fast-forward only, so a diverged or rewound history is refused
rather than reset to. The command refuses to run while tracked files are
modified, so commit or stash first. Untracked `.local` files never block it.

## Uninstalling

```sh
dotfiles-uninstall            # remove links, restore backups
dotfiles-uninstall --purge    # also delete generated cache and state
```

Uninstall is driven by the manifest at `$XDG_STATE_HOME/dotfiles/manifest`. It
removes the links the manifest lists (only while they still point into this
repository), restores each `*.bak`, and then removes any directory those
removals left empty, up to `$HOME`. It never removes your untracked `.local`
files.

> **Warning:** `--purge` deletes `$XDG_STATE_HOME/zsh`, which holds your shell
> history (`$XDG_STATE_HOME/zsh/history`, by default
> `~/.local/state/zsh/history`). Copy that file somewhere else first if you want
> to keep it.

Both forms leave `~/.config/git/config` in place. The installer wrote it as a
real file that includes the tracked git config, and it is where
`git config --global` writes, so it may hold settings you added. Once the
repository is gone, delete it by hand if you no longer want it:

```sh
rm ~/.config/git/config
```

To reinstall and keep your history, uninstall without `--purge`:

```sh
dotfiles-uninstall && ./install.sh && exec zsh
```

## Security model

You are being asked to run a shell script that links a repository into your home
directory and then loads it on every shell start. These are the properties that
make that reviewable, and where each one is enforced.

| Property | Where it is enforced |
| --- | --- |
| No plugin manager and no runtime download. The three zsh plugins are submodules pinned to exact commits, loaded by a static loader. | `.gitmodules`, `zsh/zshrc`, [architecture](docs/architecture.md#plugins-and-the-supply-chain) |
| The fast-syntax-highlighting theme download is neutralized, so a pinned commit cannot be bypassed at source time. | `zsh/zshrc`, `tests/fsyh_fetch_test.sh`, [architecture](docs/architecture.md#neutralizing-the-fast-syntax-highlighting-theme-fetch) |
| Object checking is on for every fetch (`transfer`, `fetch` and `receive.fsckObjects`), and the upgrade path re-asserts it after scrubbing ambient git config, so a hostile global config cannot turn it off. | `config/git/config`, the `vgit` wrapper in `install.sh`, `tests/git_config_test.sh` |
| The upgrade merge is `--ff-only`, so a rewound or diverged remote history is refused rather than checked out. | `install.sh`, [architecture](docs/architecture.md#the-upgrade-path) |
| Nothing on the interactive startup path runs a subprocess or waits on the network. The single exception is the update check: at most once every 3 days it launches a detached background `git fetch` of this repository, and `DOTFILES_UPDATE_DISABLE=1` turns it off. | `make forkgate`, [development](docs/development.md#what-make-forkgate-does), [architecture](docs/architecture.md#the-one-sanctioned-background-spawn) |
| No user file is overwritten without a `.bak` copy first, and uninstall restores it. | `lib/link.sh`, `lib/uninstall.sh`, `tests/uninstall_test.sh` |
| Two independent secret scanners run as gates over the tree in `make local-ci` and in CI on every push and pull request. | `make secret-scan`, `make gitleaks`, [development](docs/development.md#the-two-secret-scanners) |

None of this verifies signatures on what you fetch. `dotfiles-upgrade` is a
fetch plus a fast-forward merge, and it trusts whatever the remote you cloned
from serves. Read the diff before you upgrade if that matters to you.

To report a vulnerability, use the private advisory form linked from
[SECURITY.md](SECURITY.md). Never a public issue.

## Documentation

| Page | Read it when |
| --- | --- |
| [Architecture](docs/architecture.md) | You want to know how the framework works and why it is built this way. |
| [Shell reference](docs/shell-reference.md) | You need the exact commands, aliases, variables and config files. |
| [Provision a new mac host](docs/new-mac-host.md) | You are setting up a machine from nothing. |
| [Troubleshooting](docs/troubleshooting.md) | Something is broken and you want the symptom, cause and fix. |
| [Backup and restore](docs/backup-restore.md) | You are setting up or using the restic and rclone backups. |
| [Development](docs/development.md) | You are changing the repository and need the quality gates. |

## Contributing

Everything in the repository (code, comments, documentation, commit messages) is
written in English. Commits are SSH-signed. `make lint` must pass before every
commit and `make local-ci STRICT=1` before every push. The gates and what each
one proves are in [development](docs/development.md).

[CONTRIBUTING.md](CONTRIBUTING.md) is the page to read before opening a pull
request: the toolchain, the commit and signing rules, and the surfaces that
need a maintainer decision before the code is written. Participation is covered
by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Credits

The framework began as a port of a [prezto](https://github.com/sorin-ionescu/prezto)
setup, and two blocks of prezto's code are still in it: the `ls` listing aliases
in `zsh/aliases.zsh` and the compsys styling in `zsh/zshrc`. The `$LS_COLORS`
palette is the GNU coreutils `dircolors` database, and the Neovim bootstrap is
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
