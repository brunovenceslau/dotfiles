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
or if you will register a signing key with `gh` in step 5.

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
  of a config file, and fails with `could not lock config file` if it is
  missing.
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

The installer tries to set your git identity and signing key from this host's
allowed-signers file and ssh-agent. On a fresh host it has neither yet, so it
prints one `identity:` line saying what is missing and that every commit fails
until this host has a signing key, then a warning that git refuses every
commit. Both are expected here: the tracked git config turns commit signing
on, and step 5 sets the key up.

## 4. Remove a legacy `~/.gitconfig`

Skip this step on a machine that never had a `~/.gitconfig`. Do it before
step 5: git reads `~/.gitconfig` after the framework's XDG config, so a
`user.email` or `user.signingkey` left there wins, and the identity step
keeps any value it finds and writes nothing beside it.

The framework is XDG-only. Back the file up and remove it:

```sh
cp ~/.gitconfig ~/.gitconfig.bak && rm ~/.gitconfig
test -e ~/.gitconfig || echo "removed"
```

The framework's own git config turns commit signing on, so from here until
step 5 sets this host's key, every commit fails. Move any other setting you
still want, such as an alias, into `~/.config/git/config.local`.

Other leftovers from a prezto or antidote setup are not touched by the installer
and are safe to delete once the new shell works:

| Leftover | Why it is dead |
| --- | --- |
| `~/.config/zsh/.antidote/` | A plugin manager's clone cache. This framework has no plugin manager. |
| `~/.config/zsh/.zsh_plugins.zsh` and its `.zwc` | A generated static bundle that could shadow the new loader. |
| `~/.config/starship.toml` | The prompt config now lives at `~/.config/starship/starship.toml`, and `STARSHIP_CONFIG` points there. A stale loose file makes it a coin flip which one you edit. |
| `~/.zshrc`, `~/.zpreztorc` | Inert once `ZDOTDIR` moves interactive config under `~/.config/zsh`. |

The installer backs up any real `~/.zshenv` it replaced to `~/.zshenv.bak`.

## 5. Set identity and signing

Each host signs with its own SSH key. The identity step reads that key from
the ssh-agent, finds it with your email in an allowed-signers file, and
writes the identity into the untracked `~/.config/git/config.local`, never
into the tracked config. If this host's key is already loaded and listed,
skip to item 5.

1. Generate a dedicated signing key:

   ```sh
   ssh-keygen -t ed25519 -C "$(hostname -s) signing" -f ~/.ssh/id_signing
   ```

2. Load it into the ssh-agent, keeping its passphrase in the macOS Keychain:

   ```sh
   ssh-add --apple-use-keychain ~/.ssh/id_signing
   ssh-add -l
   ```

   `ssh-add -l` lists the key's fingerprint. After a reboot the agent starts
   empty: `ssh-add --apple-load-keychain` loads every key whose passphrase
   the Keychain holds, without a prompt. These two lines in `~/.ssh/config`
   make `ssh` add a key to the agent, with its Keychain passphrase, when it
   uses that key:

   ```text
   Host *
     UseKeychain yes
     AddKeysToAgent yes
   ```

   This is macOS's own mechanism, and the framework's tests do not cover it.
   After a reboot, check with `ssh-add -l` before you commit.

3. List the key, with the email this host commits as, in the
   allowed-signers file. The commands, the check, and how to copy the line
   to your other hosts are in
   [list a host's key](signing-key.md#list-a-hosts-key-in-the-allowed-signers-file).

4. Register the key on GitHub as a signing key, so GitHub shows your commits
   as Verified:

   ```sh
   gh auth refresh -h github.com -s admin:ssh_signing_key
   gh ssh-key add ~/.ssh/id_signing.pub --type signing --title "$(hostname -s) signing"
   gh auth refresh -h github.com --remove-scopes admin:ssh_signing_key
   ```

   `gh auth login` does not grant the `admin:ssh_signing_key` scope, so
   without the first `gh auth refresh` line `gh ssh-key add --type signing`
   fails and asks for it. The refresh opens the same browser flow as the
   login; the last line drops the scope again.

5. Set the identity, and your name once:

   ```sh
   cd ~/.config/dotfiles && ./install.sh identity --name "Your Name"
   ```

   On a fresh host it prints:

   ```text
   install: identity: wrote user.name, user.email, user.signingkey, tag.gpgsign, gpg.ssh.allowedSignersFile to /Users/you/.config/git/config.local
   ```

   It names only the keys it added, and never overwrites a value already
   set. `commit.gpgsign` is not among them: the tracked config sets it. If
   it says it is writing nothing, its message names the missing piece; the
   fixes are in
   [the installer did not set the git identity](troubleshooting.md#the-installer-did-not-set-the-git-identity).

6. Check the result. `doctor` prints nothing when the identity and signing
   are in place:

   ```sh
   ./install.sh doctor; echo "exit=$?"
   ```

   Then sign a commit in a scratch repository, as
   [check which identity and key git uses](signing-key.md#check-which-identity-and-key-git-uses)
   shows. Never sign the check in the checkout: a local commit there blocks
   the next `dotfiles-upgrade`, which only fast-forwards.

From now on `./install.sh link` and every `dotfiles-upgrade` check that the
key still verifies, and say so in one line when it does not. Rotating it,
revoking it, and keeping a host from signing are in
[manage this host's signing key](signing-key.md).

### Without python3 or an ssh-agent, set it by hand

The identity step needs a working `python3` (the Command Line Tools) and an
ssh-agent. Without them, set the values yourself:

```sh
git config --file ~/.config/git/config.local user.name  "Your Name"
git config --file ~/.config/git/config.local user.email "you@example.com"
git config --file ~/.config/git/config.local user.signingkey ~/.ssh/id_signing.pub
git config --file ~/.config/git/config.local gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers
git -C ~ config --show-origin --get user.signingkey
```

The last line names `~/.config/git/config.local`. The tracked config sets
`gpg.format = ssh` and `commit.gpgsign = true` and carries no key, so until
`user.signingkey` is set every commit fails. Verify with the
scratch-repository commit in item 6.

## 6. Install the packages

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

## 7. Verify

The host is provisioned when all of these hold:

```sh
zsh -i -c exit ; echo "exit=$?"      # exit=0, and nothing on stderr
readlink ~/.zshenv                    # points into ~/.config/dotfiles
git -C ~ config --show-origin --get user.email   # your email, from config.local
git -C ~/.config/dotfiles submodule status   # three lines, none prefixed with '-'
~/.config/dotfiles/install.sh doctor  # prints nothing
```

If any check fails, see [troubleshooting](troubleshooting.md).

## What to do next

- Put host-specific settings in the
  [`.local` layer](shell-reference.md#local-files).
- Set up backups with [backup and restore](backup-restore.md).
- Read the [shell reference](shell-reference.md) for the commands and aliases
  you now have.
