<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Provision a new mac host

Take a mac from nothing to a working host: a clone of this repository that loads
the framework and carries this machine's git identity.

Audience: anyone setting a machine up with this framework. Time: about 15
minutes, most of it Homebrew. For the reasoning behind each step, see
[architecture](architecture.md).

## Before you start

You need admin rights on the mac. A GitHub account is needed only if you will
push your own changes. Modern macOS already runs zsh as the login shell. Check
with
`echo $SHELL`, and run `chsh -s /bin/zsh` if it is something else.

## 1. Install the prerequisites

```sh
xcode-select --install     # git and the compiler toolchain
```

Homebrew is the one remote bootstrap in this whole procedure. It is interactive,
and the framework never runs it for you:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install gh        # only for step 2 and for registering a signing key
```

## 2. Authenticate to GitHub (only if you will push)

Skip this step if you only want to install the framework: the HTTPS clone in
step 3 needs no credentials. Do it if you will push to your own fork,
or if you will register a signing key with `gh` in step 4.

Repository access and commit signing use separate keys. Cloning needs neither.
Push access goes over HTTPS, authenticated by `gh`:

```sh
gh auth login                       # choose HTTPS
mkdir -p ~/.config/git
GIT_CONFIG_GLOBAL="$HOME/.config/git/config.local" gh auth setup-git
```

Three details matter here:

- `gh auth setup-git` is required. `gh auth login` alone does not make git use
  the credential helper, and a later `pull` will prompt for
  `Username for github.com`.
- `mkdir -p ~/.config/git` is required. git does not create the parent directory
  of a config file, and fails with `could not lock config file` if it is missing.
- The `GIT_CONFIG_GLOBAL` prefix puts the helper in the untracked
  `~/.config/git/config.local`, which the `~/.config/git/config` the installer
  writes in step 3 includes. Without the prefix, `gh auth setup-git` writes the
  helper to `~/.gitconfig`. The framework keeps git config under XDG paths, and
  `dotfiles-upgrade` reads only the XDG config when it fetches, so a helper in
  `~/.gitconfig` never reaches the upgrade.

## 3. Clone and install

```sh
git clone --recurse-submodules https://github.com/brunovenceslau/dotfiles.git ~/.config/dotfiles
cd ~/.config/dotfiles && ./install.sh && exec zsh
```

`--recurse-submodules` matters: the zsh plugins are pinned submodules. A
non-recursive clone leaves them empty and the shell degrades to a plain prompt
with no highlighting or autosuggestions. `install.sh` repairs this on its next
run, but cloning recursively avoids the detour. If you already cloned flat:

```sh
git -C ~/.config/dotfiles submodule update --init --recursive
```

`install.sh` writes nothing outside `$HOME`. It backs up any file, or any
symlink pointing outside the repository, it would overwrite to `<file>.bak`,
and records every link it creates in `$XDG_STATE_HOME/dotfiles/manifest`.

The installer prints a warning if commit signing is not configured. That is
expected on a fresh host. Step 4 fixes it.

## 4. Set identity and signing

Identity lives in the untracked local config, never in the tracked one:

```sh
git config --file ~/.config/git/config.local user.name  "Your Name"
git config --file ~/.config/git/config.local user.email "you@example.com"
```

To SSH-sign this host's commits, generate a dedicated key and register it as a
signing key. The tracked config sets `gpg.format = ssh` and carries no key, so a
clone without one can still commit:

```sh
ssh-keygen -t ed25519 -C "dotfiles signing $(hostname -s)" -f ~/.ssh/id_signing
gh auth refresh -h github.com -s admin:ssh_signing_key
gh ssh-key add ~/.ssh/id_signing.pub --type signing --title "$(hostname -s) signing"
git config --file ~/.config/git/config.local user.signingkey ~/.ssh/id_signing.pub
git config --file ~/.config/git/config.local commit.gpgsign true
```

`gh auth login` does not grant the `admin:ssh_signing_key` scope, so without
the `gh auth refresh` line `gh ssh-key add --type signing` fails and asks for
it. The refresh opens the same browser flow as the login.

Nothing in the framework verifies signatures. `dotfiles-upgrade` is a fetch plus
a fast-forward merge. Signing exists for GitHub's Verified badge and for your own
`git log --show-signature`. To make local verification work, add an
`allowedSignersFile` entry as shown in `config/git/config.local.example`.

## 5. Install the packages

```sh
cd ~/.config/dotfiles && ./install.sh packages
```

This runs `brew bundle` over `packages/Brewfile`, then `Brewfile.local` if you
created one, then the pinned `gh` extensions. Re-running it is safe.

Start a new shell afterwards, so the prompt and `z` pick up the freshly cached
integrations:

```sh
exec zsh
```

## 6. Remove a legacy `~/.gitconfig`

Skip this section on a machine that never had one.

If the mac carried a `~/.gitconfig` from an earlier setup, it shadows the
framework's XDG config: git reads `~/.gitconfig` with higher precedence, so
outside the dotfiles repository you would still use the old key and pager. This
framework is XDG-only. Back the file up and remove it:

```sh
cp ~/.gitconfig ~/.gitconfig.bak && rm ~/.gitconfig
```

A legacy `~/.gitconfig` usually carried a global `commit.gpgsign = true`.
Removing it turns signing off unless `config.local` sets it. If you did step 4,
`config.local` already carries it. Verify, because nothing else will tell you.
The commit below has no `-S` on purpose: it is signed only if signing is on by
default, which is the property this checks.

```sh
git config --get --type=bool commit.gpgsign                       # want: true
git -C ~/.config/dotfiles commit --allow-empty -m "signing smoke"
git -C ~/.config/dotfiles cat-file commit HEAD | grep -c gpgsig   # want: 1
git -C ~/.config/dotfiles reset --soft HEAD~1                     # discard it
```

Do not use `git log --format=%G?` to check this. It reports `N` even for a good
SSH signature unless git can see an allowed-signers file. The `cat-file` check
above answers the narrower question, "is this commit signed at all".

Other leftovers from a prezto or antidote setup are not touched by the installer
and are safe to delete once the new shell works:

| Leftover | Why it is dead |
| --- | --- |
| `~/.config/zsh/.antidote/` | A plugin manager's clone cache. This framework has no plugin manager. |
| `~/.config/zsh/.zsh_plugins.zsh` and its `.zwc` | A generated static bundle that could shadow the new loader. |
| `~/.config/starship.toml` | The prompt config now lives at `~/.config/starship/starship.toml`, and `STARSHIP_CONFIG` points there. A stale loose file makes it a coin flip which one you edit. |
| `~/.zshrc`, `~/.zpreztorc` | Inert once `ZDOTDIR` moves interactive config under `~/.config/zsh`. |

The installer backs up any real `~/.zshenv` it replaced to `~/.zshenv.bak`.

## 7. Verify

The host is provisioned when all of these hold:

```sh
zsh -i -c exit ; echo "exit=$?"      # exit=0, and nothing on stderr
readlink ~/.zshenv                    # points into ~/.config/dotfiles
git config --get user.email           # the identity you set in step 4
git -C ~/.config/dotfiles submodule status   # three lines, none prefixed with '-'
```

If you wired signing, an empty commit still carries a `gpgsig` header after the
cleanup in step 6.

If any check fails, see [troubleshooting](troubleshooting.md).

## What to do next

- Put host-specific settings in the [`.local` layer](shell-reference.md#local-files).
- Set up backups with [backup and restore](backup-restore.md).
- Read the [shell reference](shell-reference.md) for the commands and aliases you
  now have.
