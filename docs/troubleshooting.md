<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Troubleshooting

Symptoms, causes and fixes, keyed to the exact message each tool prints. Messages
from `install.sh` and its wrappers are prefixed with `install:`. Warnings and
errors go to stderr; progress lines such as `upgrade: already up to date` go to
stdout. `tests/troubleshooting_messages_test.sh` fails when a message quoted on
this page no longer exists in the code.

| Symptom | Section |
| --- | --- |
| Slow shell, blank prompt, missing completions or highlighting | [Degraded shell](#degraded-shell) |
| `z` does not exist, or the prompt is plain zsh | [The prompt or `z` is missing](#the-prompt-or-z-is-missing) |
| `canga <TAB>` completes nothing | [canga has no completion](#canga-has-no-completion) |
| Commits go out unsigned, no Verified badge | [Unsigned commits](#unsigned-commits) |
| gpg cannot ask for the passphrase, no `pinentry-mac` window | [pinentry does not appear on Intel](#pinentry-does-not-appear-on-intel) |
| `git pull` asks `Username for github.com` | [Git prompts for a username](#git-prompts-for-a-username) |
| `git: ~/.config/git/config exists - leaving the machine-local file intact` on a first install | [Framework git settings do not apply](#framework-git-settings-do-not-apply) |
| `upgrade: tracked files have local modifications` | [Upgrade refuses a dirty tree](#upgrade-refuses-a-dirty-tree) |
| `upgrade: another upgrade appears to be in progress` | [Stale upgrade lock](#stale-upgrade-lock) |
| `upgrade: fetch failed` | [Upgrade fetch fails](#upgrade-fetch-fails) |
| `upgrade: fast-forward merge refused` | [Upgrade refuses to merge](#upgrade-refuses-to-merge) |
| `updates are available`, or `no successful update check in over <n> days` | [Update notices do not go away](#update-notices-do-not-go-away) |
| `link: refusing to replace an existing directory` | [Install refuses a link](#install-refuses-a-link) |
| `link: backup already exists, refusing to overwrite` | [Install refuses a link](#install-refuses-a-link) |
| `link: unknown OS suffix on config/...` | [Install refuses a link](#install-refuses-a-link) |
| `one or more links could not be created` | [Install refuses a link](#install-refuses-a-link) |
| `packages: Homebrew is not installed` | [Packages will not install](#packages-will-not-install) |
| Uninstall left files behind | [Uninstall left something behind](#uninstall-left-something-behind) |
| tmux says `missing or unsuitable terminal`, or typed input echoes twice | [Terminal type is not recognized](#terminal-type-is-not-recognized) |

## Degraded shell

The shell is noticeably slow, the prompt is blank, syntax highlighting and
autosuggestions are missing, or Tab completion does not fire.

**Most likely cause: empty plugin submodules.** A clone without
`--recurse-submodules` leaves `zsh/plugins/*` empty, so the static loader has
nothing to source.

```sh
git -C ~/.config/dotfiles submodule status    # a leading '-' means uninitialized
git -C ~/.config/dotfiles submodule update --init --recursive
exec zsh
```

Re-running the installer fixes this too, because it re-initializes missing
submodules:

```sh
cd ~/.config/dotfiles && ./install.sh && exec zsh
```

**Second cause: a stale or foreign completion dump.** A dump left by a previous
framework can shadow this one. Clear it and let the next shell rebuild:

```sh
rm -f "${XDG_CACHE_HOME:-$HOME/.cache}"/zsh/*.zwc \
      "${XDG_CACHE_HOME:-$HOME/.cache}"/zsh/zcompdump*
exec zsh
```

At most one shell every 24 hours runs a full `compinit` with the
insecure-directory audit, plus the first shell after the completion cache is
cleared. Only that one is slow. If every shell is slow, measure it and look at
what you added:

```sh
for i in 1 2 3 4 5; do time zsh -i -c exit; done
make -C ~/.config/dotfiles forkgate     # proves the startup path forks nothing
```

**Third cause: group-writable plugin directories.** A clone or submodule
checkout made under `umask 002` leaves `zsh/plugins` group-writable. compinit's
audit then runs `getent` on every audited start, and on a shared group it asks
whether to use the "insecure directories". `./install.sh` and
`./install.sh link` remove that permission; to fix it by hand:

```sh
chmod -R go-w ~/.config/dotfiles/zsh/plugins
```

A synchronous subprocess or network call in `.zshrc.local` is the usual cause.
The fork gate measures the tracked path only, so it will not flag your own local
file, but it will confirm the framework is not the problem.

## The prompt or `z` is missing

The prompt is zsh's default, or `z` reports `command not found`.

**Cause.** Both integrations are sourced from a cache that `install.sh` writes.
The zshrc guards on the cache file, not on the binary, so a missing binary means
a missing cache and a silent degrade.

```sh
command -v starship zoxide                              # are they installed?
ls "${XDG_CACHE_HOME:-$HOME/.cache}"/zsh/*-init.zsh     # is the cache there?
```

**Fix.** Install the binaries, then regenerate the caches and reload:

```sh
cd ~/.config/dotfiles && ./install.sh packages && ./install.sh link && exec zsh
```

`install.sh link` is what refreshes the caches. It also removes a stale cache
whose binary has since been uninstalled.

## canga has no completion

`canga <TAB>` offers files, or nothing, instead of the subcommands.

**Cause.** The completion is sourced from a cache that `install.sh` writes only
when it finds `canga` on `PATH` or in `~/.local/bin` at install, link or
upgrade time. A `canga` installed after the last of those has no cache yet.

```sh
command -v canga                                             # is it installed?
ls "${XDG_CACHE_HOME:-$HOME/.cache}"/zsh/canga-completion.zsh  # is the cache there?
```

**Fix.** Regenerate the caches, then reload the shell:

```sh
dotfiles-upgrade
exec zsh
```

`dotfiles-upgrade` relinks and regenerates the caches even when it reports
`already up to date`. The caches are written only after every link succeeds.

If `dotfiles-upgrade` prints `upgrade did not complete`, read the `upgrade:`
warning above it. Four of them stop the upgrade before it relinks, and each has
its own section: [a dirty tree](#upgrade-refuses-a-dirty-tree),
[a held lock](#stale-upgrade-lock), [a failed fetch](#upgrade-fetch-fails) and
[a refused merge](#upgrade-refuses-to-merge). To get the completion without
resolving those first, run the relink directly. It needs no network and ignores
the git state:

```sh
~/.config/dotfiles/install.sh link
exec zsh
```

If the relink itself prints `one or more links could not be created`, no cache
was written. Resolve the refused link first, see
[Install refuses a link](#install-refuses-a-link).

A `canga upgrade` does not need this step. The cached script asks the binary
for its completions on every TAB, so new subcommands appear without a refresh.

## Unsigned commits

GitHub shows no Verified badge, or the installer warns
`commit signing is NOT enabled on this host (commit.gpgsign is unset)`.

**Cause.** Signing config lives in the untracked `config.local`, not in a global
`~/.gitconfig`. Removing a legacy `~/.gitconfig` drops its global
`commit.gpgsign = true`, and commits then go out unsigned. Nothing in the
framework refuses an unsigned commit.

**Diagnose.** Do not trust `git log --format=%G?`: it reports `N` even for a good
SSH signature unless git can see an allowed-signers file. Check the raw commit
instead:

```sh
git cat-file commit HEAD | grep -c gpgsig     # 0 means unsigned
```

**Fix.**

```sh
git config --file ~/.config/git/config.local user.signingkey ~/.ssh/id_signing.pub
git config --file ~/.config/git/config.local commit.gpgsign true
git commit --amend --no-edit -S
git cat-file commit HEAD | grep -c gpgsig     # want: 1
```

**Also check for a shadowing `~/.gitconfig`.** The installer warns when one
carries signing settings. A legacy GPG `signingkey` against the framework's
`gpg.format = ssh` makes commits fail outright while `commit.gpgsign` still reads
true. Remove the file, as in
[new mac host, step 6](new-mac-host.md#6-remove-a-legacy-gitconfig). To stay on
GPG for now, set `gpg.format = openpgp` in `config.local`.

## pinentry does not appear on Intel

A gpg operation that needs the passphrase fails instead of opening the
`pinentry-mac` window, and the agent reports it cannot run the configured
pinentry program.

**Cause.** `gpg-agent.conf` has no include directive and no variable expansion,
so `pinentry-program` must be an absolute path and cannot be derived from the
Homebrew prefix the way the shell derives it. The tracked file carries the Apple
Silicon prefix. On Intel, Homebrew installs under `/usr/local`, so that path does
not exist:

```sh
grep pinentry-program ~/.gnupg/gpg-agent.conf   # /opt/homebrew/bin/pinentry-mac
ls /usr/local/bin/pinentry-mac                  # where Intel actually has it
```

**Fix.** `~/.gnupg/gpg-agent.conf` is a link into the repository, so point the
repository copy at the Intel path and reload the agent:

```sh
$EDITOR ~/.config/dotfiles/config/gnupg/gpg-agent.conf
gpgconf --kill gpg-agent
```

That leaves a tracked file modified, and `dotfiles-upgrade` refuses to merge over
local modifications, see [Upgrade refuses a dirty tree](#upgrade-refuses-a-dirty-tree).

Replacing the link with a real file instead keeps the tree clean, but is not
durable: the next `./install.sh link` backs the file up to
`~/.gnupg/gpg-agent.conf.bak` and restores the link. Writing the real file a
second time then makes that link fail, because the engine refuses to overwrite an
existing backup, see [Install refuses a link](#install-refuses-a-link).

## Git prompts for a username

`git pull` or `git fetch` drops to `Username for github.com`.

**Cause.** The remote needs credentials and none are wired: you are pushing, or
the remote is a private fork. Either `gh` is not wired as the credential helper,
or the helper was written to `~/.gitconfig` and disappeared with the XDG-only
cleanup. `gh auth login` alone is not enough. A read-only clone of the public
repository never reaches this.

**Fix.**

```sh
mkdir -p ~/.config/git
GIT_CONFIG_GLOBAL="$HOME/.config/git/config.local" gh auth setup-git
```

Or add the block by hand. `config/git/config.local.example` shows it, commented,
as the `[credential "https://github.com"]` stanza. This applies to HTTPS remotes
only. An SSH remote authenticates with your SSH key (through the SSH agent) and
needs no credential helper.

## Framework git settings do not apply

```
install: git: ~/.config/git/config exists - leaving the machine-local file intact
```

**Cause.** `~/.config/git/config` was already a real file when you first ran the
installer. The installer never rewrites that file, so it does not add the
`[include]` of the tracked `config/git/config`, and none of the framework's git
settings apply: `fsckObjects` on every fetch, SSH signing, the pager and the
rest. On a re-run the same line is expected and harmless, because the file is
then the one the installer wrote.

To check, ask git where `transfer.fsckObjects` comes from:

```sh
git -C ~ config --show-origin --get transfer.fsckObjects
```

The setting applies when the output names your checkout's `config/git/config`
and the value `true`. Empty output means the tracked config is not included.

**Fix.** Add the two includes the installer writes into a new file, at the top
of your existing `~/.config/git/config`. Settings further down the file then
still override the tracked ones. Use the absolute path of your checkout; a
relative path would resolve against `~/.config/git`.

```ini
[include]
	path = /Users/you/.config/dotfiles/config/git/config
[include]
	path = config.local
```

The second include reads `~/.config/git/config.local`, where your git identity
and signing key go. Run the check again to confirm.

## Upgrade refuses a dirty tree

```
install: upgrade: tracked files have local modifications - commit or stash first
```

**Cause.** A fast-forward cannot apply cleanly over uncommitted tracked edits.
Untracked `.local` files never trigger this.

**Fix.**

```sh
git -C ~/.config/dotfiles status --porcelain --untracked-files=no
git -C ~/.config/dotfiles stash        # or commit
dotfiles-upgrade
```

## Stale upgrade lock

```
install: upgrade: another upgrade appears to be in progress
```

**Cause.** The upgrade takes a single-flight lock by creating a directory. A trap
releases it on exit and on Ctrl-C, but a hard kill can orphan it.

**Fix.** If no upgrade is running, remove the lock directory. The message prints
its exact path:

```sh
rmdir ~/.local/state/dotfiles/upgrade.lock
```

## Upgrade fetch fails

```
install: upgrade: fetch failed
```

**Cause.** The network is unreachable, or the remote needs credentials the
upgrade cannot see. The upgrade's fetch scrubs ambient git configuration, to
neutralize a hostile `url.insteadOf` or `gpg.ssh.program`. It then re-injects
only the credential helper it can read from the XDG config. A helper that lives
anywhere else is not seen, and the fetch runs with `GIT_TERMINAL_PROMPT=0`, so
it fails instead of prompting. Credentials only matter when the remote is a
private fork or an SSH URL; the public HTTPS remote fetches without them.

**Fix.** Check the network first. If the remote needs credentials, put the
helper where the upgrade reads it:

```sh
git config -f ~/.config/git/config.local \
  'credential.https://github.com.helper' '!gh auth git-credential'
```

Or switch the remote to SSH. See also
[Git prompts for a username](#git-prompts-for-a-username).

## Upgrade refuses to merge

```
install: upgrade: fast-forward merge refused (diverged or rewound history)
```

**Cause.** This is the anti-rollback guard working. Your local history is not an
ancestor of the fetched tip, either because you have local commits or because the
remote history was rewritten. The upgrade will not reset to it.

**Fix.** Inspect what diverged, then resolve it by hand:

```sh
git -C ~/.config/dotfiles log --oneline --graph --decorate HEAD origin/main
```

If you have local commits, push or rebase them. If the remote was rewritten on
purpose, reset deliberately and knowingly. The upgrade path will never do it for
you.

## Update notices do not go away

```
dotfiles: updates are available - run 'dotfiles-upgrade' to apply them.
dotfiles: no successful update check in over 30 days - the update channel may be stalled (run 'dotfiles-upgrade').
```

**"Updates are available"** means the background fetch saw the remote ahead. Run
`dotfiles-upgrade`. A successful upgrade clears the sentinel. If the notice
survives an upgrade, clear the stale file:

```sh
rm -f ~/.local/state/dotfiles/update-available
```

**"No successful update check in over N days"** means no background fetch has succeeded
within the staleness window, usually because the host is offline or
authentication is broken. Run `dotfiles-upgrade` by hand to see the real error.

Tune or disable the sentinel from `~/.config/zsh/.zshrc.local`, which is read
before it runs:

```sh
DOTFILES_UPDATE_CADENCE_DAYS=7        # fetch less often (default 3)
DOTFILES_UPDATE_STALENESS_DAYS=60     # freeze warning threshold (default 30)
DOTFILES_UPDATE_DISABLE=1             # turn the sentinel off (any non-empty value)
```

## Install refuses a link

The installer never silently destroys anything. Four warnings are possible. The
first, second and fourth are refusals: the installer places every other link
and caches the shell integrations, skips initializing missing plugin submodules
(it warns `skipping plugin submodule init because a link was refused`), then
prints the message below and exits 1. The re-run after the fix completes the
submodule step.

```
install: one or more links could not be created (see warnings above)
```

The third, an unknown `@suffix`, skips that one directory and does not fail the
install.

| Message | Meaning | Fix |
| --- | --- | --- |
| `link: refusing to replace an existing directory: <path>` | A real directory sits where a link belongs. Backing up and restoring a directory is not idempotent, so this needs your decision. | Move or remove the directory, then re-run `./install.sh`. |
| `link: backup already exists, refusing to overwrite: <path>.bak` | A previous install already saved the pristine file. That first backup is the one worth keeping. | Inspect both files, keep what you want, remove or rename the `.bak`, then re-run. |
| `link: unknown OS suffix on config/<name>` | A `config/` subdirectory contains `@`. No suffix is recognized, because macOS is the only target. | Rename the directory without the `@` part. |
| `link: source missing, skipping: <path>` | A link rule points at a file that is not in the checkout. | Usually an incomplete clone. Re-clone, or restore the file. |

## Packages will not install

```
install: packages: Homebrew is not installed.
install: packages: install it via the official method at https://brew.sh, then re-run 'install.sh packages'.
```

**Cause.** This is deliberate. The installer will not run a remote bootstrap
script on your behalf.

**Fix.** Install Homebrew yourself, as in
[new mac host, step 1](new-mac-host.md#1-install-the-prerequisites), then re-run
`./install.sh packages`.

A failing `gh` extension install only warns. It never fails the package step.

## Uninstall left something behind

```
install: uninstall: <path> no longer points into the repo (-> <target>) - leaving it
install: uninstall: <path> is not our symlink anymore - leaving it
install: uninstall: not restoring <path>.bak - something occupies <path>
```

**Cause.** These are safety refusals, not bugs. Uninstall removes a listed path
only while it is still a symlink into the repository, so anything you replaced by
hand survives.

**Fix.** Inspect the path and remove it yourself if you want it gone.

Two things are left on purpose, with no message:

- `~/.config/git/config`, the machine-local git config the installer wrote. It
  is where `git config --global` writes, so it can hold your own settings.
  Delete it by hand if you no longer want it.
- An empty directory the uninstall did not empty itself. Directories are pruned
  only when a removed link leaves them empty.

`--purge` does **not** leave your shell history: it deletes
`$XDG_STATE_HOME/zsh`, which holds it. See
[Uninstalling](../README.md#uninstalling).

```
install: uninstall: refusing to run as root over a manifest owned by uid <n>
```

**Cause.** A user-writable manifest must never drive privileged deletions.

**Fix.** Run uninstall as the owning user. Sudo is never needed.

Directories are pruned only while they are empty, so a directory holding a
`.local` file stays. That is intended: `.local` files are never removed.

## Terminal type is not recognized

tmux refuses to start with `missing or unsuitable terminal`, or typed input
echoes twice over SSH.

**Cause.** `$TERM` names a terminfo entry the machine does not have. Reaching a
remote box from Ghostty before its terminfo is installed there is the common
case.

**What the framework already does.** The zshrc detects an unresolvable `$TERM`
through the `zsh/terminfo` module and falls back to `xterm-256color`. That is a
floor, not a fix for the remote entry.

**Fix on the remote machine.** Install the real entry:

```sh
infocmp -x xterm-ghostty | ssh REMOTE_HOST -- tic -x -
```

Ghostty's `ssh-terminfo` feature does this automatically. The zshrc arms it by
appending `ssh-env,ssh-terminfo` to `$GHOSTTY_SHELL_FEATURES`, which is necessary
because the tracked Ghostty config sets `shell-integration = none` and Ghostty
then ignores its own `shell-integration-features` line.
