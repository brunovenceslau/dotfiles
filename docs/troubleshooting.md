<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Troubleshooting

Symptoms, causes and fixes, keyed to the exact message each tool prints.
Messages from `install.sh` and its wrappers are prefixed with `install:`.
Warnings and errors go to stderr; progress lines such as
`upgrade: already up to date` go to stdout.
`tests/troubleshooting_messages_test.sh` fails when a message quoted on this
page no longer exists in the code.

| Symptom | Section |
| --- | --- |
| Slow shell, blank prompt, missing completions or highlighting | [Degraded shell](#degraded-shell) |
| `z` does not exist, or the prompt is plain zsh | [The prompt or `z` is missing](#the-prompt-or-z-is-missing) |
| `canga <TAB>` completes nothing | [canga has no completion](#canga-has-no-completion) |
| `sbx <TAB>` completes nothing | [sbx has no completion](#sbx-has-no-completion) |
| Commits go out unsigned, no Verified badge | [Unsigned commits](#unsigned-commits) |
| `identity: ... - writing nothing`, `is already set to a different value`, or `is overridden by` | [The installer did not set the git identity](#the-installer-did-not-set-the-git-identity) |
| `identity: user.signingkey ... is not valid for`, or `is not loaded in the ssh-agent` | [The signing key is stale](#the-signing-key-is-stale) |
| `identity: python3 is not usable here - skipping` | [The installer did not set the git identity](#the-installer-did-not-set-the-git-identity) |
| `identity: not reading the git config:` | [The installer did not set the git identity](#the-installer-did-not-set-the-git-identity) |
| `identity: signing is off against`, or `sets it false and wins` | [The installer did not set the git identity](#the-installer-did-not-set-the-git-identity) |
| `git config --global user.email` prints nothing | [`git config --global` returns empty](#git-config---global-returns-empty) |
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
| `backed up <path> -> <path>.bak` for links another checkout made, or `link: not recording the target of` | [Links from another checkout were backed up](#links-from-another-checkout-were-backed-up) |
| `packages: Homebrew is not installed` | [Packages will not install](#packages-will-not-install) |
| Uninstall left files behind | [Uninstall left something behind](#uninstall-left-something-behind) |
| `install: refusing to run as root`, or `cannot tell who is running this` | [Install refuses to run as root](#install-refuses-to-run-as-root) |
| `the manifest keeps an entry the framework may not act on` | [Manifest keeps an entry the framework may not act on](#manifest-keeps-an-entry-the-framework-may-not-act-on) |
| `<tool> <args> did not produce a completion script` (canga or sbx) | [sbx has no completion](#sbx-has-no-completion) |
| tmux says `missing or unsuitable terminal`, or typed input echoes twice | [Terminal type is not recognized](#terminal-type-is-not-recognized) |
| `make lint` fails with `check-patterns: an entry under zsh/plugins/ that is not a pinned plugin` | [check-patterns rejects a file under zsh/plugins](#check-patterns-rejects-a-file-under-zshplugins) |

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

A synchronous subprocess or network call in `.zshrc.local` is the usual cause.
The fork gate measures the tracked path only, so it will not flag your own local
file, but it will confirm the framework is not the problem.

**Third cause: group-writable plugin directories.** A clone or submodule
checkout made under `umask 002` leaves `zsh/plugins` group-writable. compinit's
audit then runs `getent` on every audited start, and on a shared group it asks
whether to use the "insecure directories". `./install.sh` and
`./install.sh link` remove that permission; to fix it by hand:

```sh
chmod -R go-w ~/.config/dotfiles/zsh/plugins
```

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
Even with a cache on disk, `zsh/zshrc` also checks `canga` is on `PATH` before
sourcing it (`(( $+commands[canga] ))`), and that check runs before
`~/.zshrc.local` is sourced - so putting `canga` on `PATH` only in
`~/.zshrc.local` still shows no completion. It needs to be reachable via
`zshenv`, `zprofile`, the detected Homebrew prefix, or `~/.local/bin` instead.

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

## sbx has no completion

`sbx <TAB>` offers files, or nothing, instead of the subcommands.

**Cause.** Same mechanism as canga above: the completion is sourced from a
cache that `install.sh` writes only when it finds `sbx` on `PATH` or in
`~/.local/bin` at install, link or upgrade time. An `sbx` installed after the
last of those has no cache yet. The same `~/.zshrc.local` timing note applies:
`zsh/zshrc` checks `sbx` is on `PATH` before sourcing its cache, and that check
runs before `~/.zshrc.local` is sourced, so `sbx` needs to be reachable via
`zshenv`, `zprofile`, the detected Homebrew prefix, or `~/.local/bin` instead.

```sh
command -v sbx                                               # is it installed?
ls "${XDG_CACHE_HOME:-$HOME/.cache}"/zsh/sbx-completion.zsh    # is the cache there?
```

**Fix.** Same fix as canga's: regenerate the caches, then reload the shell.

```sh
dotfiles-upgrade
exec zsh
```

If that does not resolve it, follow the same relink and refused-link steps as
[canga has no completion](#canga-has-no-completion) - the two tools share
`_cache_shell_inits`, so every step there applies to `sbx` unchanged.

An `sbx` upgrade does not need this step either: the cached script asks the
binary for its completions on every TAB (measured on sbx v0.45.1: the
generated script references `__complete` exactly once), so new subcommands
appear without a refresh.

**Two related, non-error messages.** If `install.sh link` (or
`dotfiles-upgrade`) prints this, `canga`/`sbx` ran but its output was not a real
completion script (cobra's zsh template emits `#compdef <tool>` first, measured
on sbx v0.45.1 and canga v0.10.5) - the same regenerate-then-reload fix above
applies once the binary itself prints one correctly:

```
install: <tool> <args> did not produce a completion script (want first line '<want>') - its shell integration is skipped
```

And a cache left behind by a canga or sbx that was later uninstalled is not an
error at all: `zsh/zshrc`'s `(( $+commands[<tool>] ))` guard skips a stale
cache silently at every shell startup, with nothing printed, until the next
`install.sh link` (or `dotfiles-upgrade`) removes the file itself.

## Unsigned commits

GitHub shows no Verified badge, or the installer warns
`commit signing is NOT enabled on this host (commit.gpgsign is unset)`.

**Cause.** Signing config lives in the untracked `config.local`, not in a global
`~/.gitconfig`. Removing a legacy `~/.gitconfig` drops its global
`commit.gpgsign = true`, and commits then go out unsigned. Nothing in the
framework refuses an unsigned commit.

**Diagnose.** Do not trust `git log --format=%G?`: it reports `N` even for a
good SSH signature unless git can see an allowed-signers file. Check the raw
commit instead:

```sh
git cat-file commit HEAD | grep -c gpgsig     # 0 means unsigned
```

**Fix.** `./install.sh identity` sets the key from your allowed-signers file
and ssh-agent (see
[the installer did not set the git identity](#the-installer-did-not-set-the-git-identity)
when it cannot). By hand:

```sh
git config --file ~/.config/git/config.local user.signingkey ~/.ssh/id_signing.pub
git config --file ~/.config/git/config.local commit.gpgsign true
git commit --amend --no-edit -S
git cat-file commit HEAD | grep -c gpgsig     # want: 1
```

**Also check for a shadowing `~/.gitconfig`.** The installer warns when one
carries signing settings. A legacy GPG `signingkey` against the framework's
`gpg.format = ssh` makes commits fail outright while `commit.gpgsign` still
reads true. Remove the file, as in
[new mac host, step 6](new-mac-host.md#6-remove-a-legacy-gitconfig). To stay on
GPG for now, set `gpg.format = openpgp` in `config.local`.

## The installer did not set the git identity

`install.sh identity` prints one of the lines below. `install`, `link` and
`dotfiles-upgrade` print only the first line of the same explanation, ending
in `(details: <checkout>/install.sh identity)`; run that command to see the
rest.

```text
install: identity: python3 is not usable here - skipping (install the Command Line Tools, then run <path to install.sh> identity)
install: identity: no allowed-signers file found - writing nothing
install: identity: cannot read the allowed-signers file <path> (from <source>): <reason> - writing nothing
install: identity: ssh-add was not found on PATH - writing nothing
install: identity: ssh-add -L did not answer within 15 seconds - writing nothing
install: identity: the ssh-agent holds no keys - writing nothing
install: identity: cannot reach an ssh-agent (ssh-add -L exited 2) - writing nothing
install: identity: no ssh-agent key is listed for the git namespace in <path> - writing nothing
install: identity: every ssh-agent key listed <where> is revoked by gpg.ssh.revocationFile <path> - writing nothing
install: identity: ssh-keygen -Q could not check the ssh-agent key(s) listed <where> against gpg.ssh.revocationFile <path> - writing nothing
install: identity: malformed allowed-signers line(s) <n> in <path> name an ssh-agent key - writing nothing
install: identity: more than one identity matches the ssh-agent keys - writing nothing
install: identity: more than one ssh-agent key is listed for <email> - writing nothing
install: identity: no ssh-agent key is listed for user.email <email> - writing nothing
install: identity: cannot read gpg.ssh.revocationFile <path>: <reason> - writing nothing
install: identity: gpg.ssh.revocationFile <path> line <n> is not a public key - writing nothing
install: identity: gpg.ssh.revocationFile <path> line <n> holds a NUL byte - writing nothing
install: identity: gpg.format is <value>, not ssh - writing nothing
install: identity: git does not read <path> (no [include] reaches it) - writing nothing
install: identity: GIT_CONFIG_GLOBAL=<value> is not <path>, so git would not read <path> - writing nothing
install: identity: not reading the git config: <reason>
install: identity: cannot read <key> (<git's error>) - writing nothing
install: identity: <key> is already set to a different value - leaving it: <value>
install: identity: <key> is overridden by <origin> - leaving it: <value>
install: identity: <key> reads <value> from <origin> after the write, not the value written
install: identity: refusing to write through the symlink <path> - add the keys by hand
install: identity: <path> is not a regular file - writing nothing
install: identity: not set automatically in an SSH session (a forwarded agent holds another machine's keys) - run <path to install.sh> identity to set it on purpose
```

In the two revocation lines, `<where>` is `in <path>`, or
`for <email> in <path>` when `user.email` is set.

**Cause.** The identity step writes only when the allowed-signers file and the
ssh-agent agree on exactly one email and exactly one key for the `git`
namespace, and it never replaces a value you set. The full rule is in
[`install.sh identity`](shell-reference.md#installsh-identity).

An explicit `commit.gpgsign = false` or `tag.gpgsign = false` that
`config.local` does not contradict is not in this list: the step keeps it as
the host's exception, writes the rest, and prints the first line below. A
`false` in `config.local` that a later `true` overrides prints the second.

```text
install: identity: <key> is false (<origin>) - kept as this host's exception, so it stays off
install: identity: <key> is false in <path>, but <origin> sets it true and wins
```

A `true` in `config.local` that a later file turns `false` is an override,
not the exception: `install.sh identity` prints `is overridden by` (above),
the `install` advisory prints the first line below, and `link` and
`dotfiles-upgrade` print the second:

```text
install: identity: <key> is true in <path>, but <origin> sets it false and wins - signing stays off
install: identity: signing is off against <path>: <key> = false from <origin> - see <path to install.sh> identity
```

**Fix.** Supply the missing piece, then re-run the step:

- `python3` is not usable: on a Mac, `/usr/bin/python3` is a stub until the
  Command Line Tools are installed. Run `xcode-select --install`.
- Not reading the git config: the step runs git from an empty directory under
  `$TMPDIR`, outside every repository, and the reason says what stopped it.
  Give `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` absolute paths, or unset
  them. Point `TMPDIR` at a directory whose path holds no `:` and that only you
  can write to, or that has the sticky bit, as `/tmp` does.
- `cannot read <key>`: git failed to read your config, and its own error is in
  the parentheses. `git config --list --show-origin` run outside a repository
  shows the same error and the file it comes from.

- No file, or one that cannot be read: list this host's key as
  `<email> <keytype> <key>` in `~/.config/git/allowed_signers`, or point
  `CANGA_HOST_ALLOWED_SIGNERS` or `gpg.ssh.allowedSignersFile` at your file.
  It must be a regular file you can read.
- No `ssh-add`, no answer, no agent or no key: `ssh-add` the signing key, and
  check `ssh-add -L` lists it.
- No match: the agent's key must appear in the file byte for byte, as
  `<keytype> <base64>`. An entry with a `namespaces` option that excludes
  `git`, an expired `valid-before`, or a key in `gpg.ssh.revocationFile` does
  not count.
- More than one identity: the message lists each email with its key
  fingerprint. Set the email this host commits as with
  `git config --file ~/.config/git/config.local user.email <email>`, and the
  step picks among that email's keys only.
- More than one key for the email: keep only this host's signing key in the
  agent (`ssh-add -d <key file>`), or retire the other entry with a past
  `valid-before`. The fingerprints in the message match `ssh-add -l`.
- No key for your `user.email`: the agent's keys are listed for another email,
  which the message names. Fix `user.email` or the allowed-signers file.
- The revocation file: fix the path in `gpg.ssh.revocationFile`, or make the
  file a KRL or a list of public keys, one per line. A line holding only a
  carriage return is not blank to `ssh-keygen`, and fails the file too. When
  every agent key listed (for your `user.email`, when the message names it)
  is revoked, load a key that is not, and list it in the allowed-signers
  file.
- A malformed line that names an agent key: this step cannot read the line,
  but the `ssh-keygen` that verifies may (glibc's, for example, takes a
  seconds field of 61), so which key is this host's is unclear. Fix the line
  or remove it.
- `gpg.format` is not `ssh`, or git does not read `config.local`: the
  framework git config is not in effect, see
  [framework git settings do not apply](#framework-git-settings-do-not-apply).
- `GIT_CONFIG_GLOBAL`: something in your environment points git at another
  global file, which does not include `config.local`. Unset it and re-run.
- A different or an overriding value: the step leaves it on purpose, and then
  writes nothing at all. Edit `~/.config/git/config.local` if the old value is
  wrong, or remove the overriding line from the file the message names. For
  `user.signingkey`, use `--rotate`, below.
- A value that reads differently after the write: another file overrides it;
  the message names the file.
- A symlinked `config.local`: add the keys to the file it points at by hand.
- A `config.local` that is not a regular file: move it aside, and let the
  step create the file.
- An SSH session: the automatic step stays out of it on purpose. Run
  `install.sh identity` there only when the agent holds this host's own key.

```sh
cd ~/.config/dotfiles && ./install.sh identity --name "Your Name"
```

## The signing key is stale

`install.sh`, or `install.sh identity`, prints one of:

```text
install: identity: user.signingkey <fingerprint> is not valid for <email> in <path> (<reason>)
install: identity: user.signingkey <fingerprint> is not loaded in the ssh-agent - signing will fail
install: identity: user.signingkey is set in <origin>, outside <path>
```

`link` and `dotfiles-upgrade` print the first one alone, as one line that
names the command to run. The second form below is for a revocation file
that cannot be checked, where `--rotate` refuses:

```text
install: identity: user.signingkey <fingerprint> is not valid for <email> in <path> (<reason>) - run <path to install.sh> identity --rotate
install: identity: user.signingkey <fingerprint> is not valid for <email> in <path> (<reason>) - see <path to install.sh> identity
```

A certificate, or a private key whose `.pub` is missing, is not a stale key:
git can sign with either, and the step only says it did not check it:

```text
install: identity: user.signingkey (<value>) is a certificate or a private key without its .pub - not checked
```

**Cause.** The configured key no longer verifies against your allowed-signers
file (its entry was retired, expired, never listed for that email, or the key
is in `gpg.ssh.revocationFile`), the ssh-agent does not hold it, or a
`user.signingkey` in another file competes with the one in `config.local`.
When several files set it, the line ends in `the last one git reads wins`.

**Fix.** For a retired or revoked key, load the new key into the agent and
rotate:

```sh
cd ~/.config/dotfiles && ./install.sh identity --rotate
```

It replaces `user.signingkey` only when exactly one agent key verifies for
your email; the rule is in
[rotating the signing key](shell-reference.md#rotating-the-signing-key). It
prints one of these when it will not:

```text
install: identity: --rotate: <fingerprint> is still valid for <email> in <path> - nothing to rotate
install: identity: --rotate: <n> ssh-agent keys are valid for <email> in <path> - refusing
install: identity: --rotate: user.signingkey comes from <origin>, not <path> - edit it there
install: identity: --rotate: user.signingkey is not set - nothing to rotate; run <path to install.sh> identity
```

For a key missing from the agent, `ssh-add` it. For a competing value, delete
the other file's `user.signingkey`.

## `git config --global` returns empty

`git config --global user.email` (or `gpg.format`, or any framework setting)
prints nothing, although commits use the right values.

**Cause.** `--global` reads one file, without includes: `~/.gitconfig` when it
exists, and `~/.config/git/config` otherwise. The framework's settings and your
identity arrive through includes (the tracked `config/git/config` and
`~/.config/git/config.local`), so `--global` never sees them. With a
`~/.gitconfig` present it does not even read `~/.config/git/config`.

**Fix.** Ask git the way a commit does, from a directory outside any
repository, and let it name the file each value came from:

```sh
git -C ~ config --show-origin --get user.email
```

## pinentry does not appear on Intel

A gpg operation that needs the passphrase fails instead of opening the
`pinentry-mac` window, and the agent reports it cannot run the configured
pinentry program.

**Cause.** `gpg-agent.conf` has no include directive and no variable expansion,
so `pinentry-program` must be an absolute path and cannot be derived from the
Homebrew prefix the way the shell derives it. The tracked file carries the Apple
Silicon prefix. On Intel, Homebrew installs under `/usr/local`, so that path
does not exist:

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

That leaves a tracked file modified, and `dotfiles-upgrade` refuses to merge
over local modifications, see
[Upgrade refuses a dirty tree](#upgrade-refuses-a-dirty-tree).

Replacing the link with a real file instead keeps the tree clean, but is not
durable: the next `./install.sh link` backs the file up to
`~/.gnupg/gpg-agent.conf.bak` and restores the link. Writing the real file a
second time then makes that link fail, because the engine refuses to overwrite
an existing backup, see [Install refuses a link](#install-refuses-a-link).

## Git prompts for a username

`git pull` or `git fetch` drops to `Username for github.com`.

**Cause.** The remote needs credentials and none are wired: you are pushing, or
the remote is a private fork. Either `gh` is not wired as the credential helper,
or the helper was written to `~/.gitconfig` and disappeared with the XDG-only
cleanup. `gh auth login` alone is not enough. A read-only HTTPS clone of the
upstream repository never reaches this.

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

**Cause.** The upgrade takes a single-flight lock by creating a directory. A
trap releases it on exit and on Ctrl-C, but a hard kill can orphan it.

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
private fork or an SSH URL; the upstream HTTPS remote fetches without them.

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
ancestor of the fetched tip, either because you have local commits or because
the remote history was rewritten. The upgrade will not reset to it.

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

**"No successful update check in over N days"** means no background fetch has
succeeded within the staleness window, usually because the host is offline or
authentication is broken. Run `dotfiles-upgrade` by hand to see the real error.

Tune or disable the sentinel from `~/.config/zsh/.zshrc.local`, which is read
before it runs:

```sh
DOTFILES_UPDATE_CADENCE_DAYS=7        # fetch less often (default 3)
DOTFILES_UPDATE_STALENESS_DAYS=60     # freeze warning threshold (default 30)
DOTFILES_UPDATE_DISABLE=1             # turn the sentinel off (any non-empty value)
```

## Install refuses a link

The installer never silently destroys anything. Six warnings are possible. All
but the unknown `@suffix` are refusals: the installer places every other link
and caches the shell integrations, skips initializing missing plugin submodules
(it warns `skipping plugin submodule init because a link was refused`), then
prints the message below and exits 1. The re-run after the fix completes the
submodule step.

```
install: one or more links could not be created (see warnings above)
```

The unknown `@suffix` skips that one directory and does not fail the install.

| Message | Meaning | Fix |
| --- | --- | --- |
| `link: refusing to replace an existing directory: <path>` | A real directory sits where a link belongs. Backing up and restoring a directory is not idempotent, so this needs your decision. | Move or remove the directory, then re-run `./install.sh`. |
| `link: backup already exists, refusing to overwrite: <path>.bak` | A previous install already saved the pristine file or symlink. That first backup is the one worth keeping. | Inspect both, keep what you want, remove or rename the `.bak`, then re-run. |
| `link: unknown OS suffix on config/<name>` | A `config/` subdirectory contains `@`. No suffix is recognized, because macOS is the only target. | Rename the directory without the `@` part. |
| `link: source missing, skipping: <path>` | A link rule points at a file that is not in the checkout. | Usually an incomplete clone. Re-clone, or restore the file. |
| `link: could not create the parent of <path>`, or `link: could not create <path>` | The parent directory could not be made, or the link could not be written. A dangling symlink on the path is the usual cause. Nothing is recorded for it. | Fix or remove the dangling symlink, then re-run. |
| `link: refusing <path> - <reason>` | The `<reason>` is `outside the home directory` when the destination is not under `$HOME` or a directory on its path is a symlink that leads out of it, and `inside the checkout` when that symlink leads into the checkout. Uninstall could never remove such a link, so it is not created. Usually `XDG_CONFIG_HOME` points outside `$HOME`. | Point `XDG_CONFIG_HOME` under `$HOME`, or replace the symlinked directory with a real one, then re-run. |

## Links from another checkout were backed up

```
install: backed up <path> -> <path>.bak
install: link: not recording the target of <path> (tab or newline in the path) - another checkout will back it up
install: link: <path> is a symlink - ignoring it, so links from another checkout are backed up
```

**Cause.** A relink replaces a link without a backup only when it points into
the checkout running the install, or when `$XDG_STATE_HOME/dotfiles/targets`
records that exact destination and target. A host installed before the targets
file existed has no pairs yet, so the first relink from a second checkout backs
up the first checkout's links once. The second message means a path holds a tab
or a newline, so its pair is never written and that link is always backed up
from another checkout. The third means the targets file is a symlink. It is
never followed, so no pair counts until a relink writes a real targets file
over the symlink.

**Fix.** Check that each `.bak` is a link into your other checkout
(`readlink <path>.bak`), then delete it. Later switches between checkouts
replace the links without a backup. Uninstall would otherwise put such a `.bak`
back.

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
install: prune: could not remove orphan link <path> - keeping it recorded
install: prune: <path> no longer produced but points outside the repo (-> <target>) - leaving it
install: prune: <path> is not our symlink anymore - keeping it and its .bak recorded
install: prune: not restoring <path>.bak - something occupies <path>
install: uninstall: refusing <path> - <reason>
```

**Cause.** These are safety refusals, not bugs. Uninstall and prune remove a
listed path only while it is still a framework link: a symlink into the
repository, or one `$XDG_STATE_HOME/dotfiles/targets` records with exactly its
current target. Anything you replaced or repointed by hand survives, and prune
keeps it in the manifest so a later uninstall still sees it. Uninstall refuses,
and exits 1 for, any listed path outside `$HOME` or reached through a symlinked
directory that leads out of `$HOME` or into the checkout, and `<reason>` names
which (`outside the home directory` or `inside the checkout`); for prune, see
[Manifest keeps an entry the framework may not act on](#manifest-keeps-an-entry-the-framework-may-not-act-on).
Prune's `not restoring` means something recreated the path between removing
the link and restoring its `.bak`.

**Fix.** Inspect the path and remove it yourself if you want it gone.

Two things are left on purpose, with no message:

- `~/.config/git/config`, the machine-local git config the installer wrote. It
  is where `git config --global` writes, so it can hold your own settings.
  Delete it by hand if you no longer want it.
- A directory the uninstall did not empty. Directories are pruned only when a
  removed link leaves them empty, so one holding a `.local` file stays;
  `.local` files are never removed.

`--purge` does **not** leave your shell history: it deletes
`$XDG_STATE_HOME/zsh`, which holds it. See
[Uninstalling](../README.md#uninstalling).

## Install refuses to run as root

```
install: refusing to run as root - run it as the owning user; sudo is never needed here
install: cannot tell who is running this (<path> is missing) - refusing to run
install: cannot tell who is running this (<path> gave no uid) - refusing to run
```

**Cause.** `install.sh` refuses root for every subcommand, before it does
anything else. As root it would act on files, directories and tools a normal
user can change, and nothing it does needs root: Homebrew is user-scoped. The
other two messages mean the check could not read the uid from `/usr/bin/id` (the
`<path>`), so it refuses rather than guess. NixOS has no `/usr/bin/id`, so the
installer does not run there.

**Fix.** Run the command as the owning user. Sudo is never needed.

## Manifest keeps an entry the framework may not act on

```
install: prune: dropping <path> from the manifest - <reason>, and nothing is there
install: prune: keeping <path> recorded - <reason>, and something is there
install: the manifest keeps an entry the framework may not act on (see warnings above)
```

**Cause.** The manifest lists a path the framework may not act on. The
`<reason>` says why: `inside the checkout` when the path is the checkout or one
of its ancestors, or is reached through a symlinked directory that leads into
the checkout; `outside the home directory` for every other refusal, such as a
path outside `$HOME`, one spelled with `..`, or one reached through a symlinked
directory that leads out of `$HOME`. The framework never writes such a line, so
it comes from a `$HOME` that moved or a hand-edited manifest. When nothing
exists at the path or at `<path>.bak`, a clean relink drops the line once and
the next run is clean. When something exists there, the line is kept and every
relink exits 1 with the third message, so nothing there is touched or
forgotten.

**Fix.** Look at the path and its `.bak` and keep or remove them yourself. Then
delete that line from `$XDG_STATE_HOME/dotfiles/manifest` and its line, if any,
from `$XDG_STATE_HOME/dotfiles/targets`, and re-run `./install.sh link`.

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
appending `ssh-env,ssh-terminfo` to `$GHOSTTY_SHELL_FEATURES`, which is
necessary because the tracked Ghostty config sets `shell-integration = none` and
Ghostty then ignores its own `shell-integration-features` line.

## check-patterns rejects a file under zsh/plugins

```
<path>/zsh/plugins/.DS_Store
check-patterns: an entry under zsh/plugins/ that is not a pinned plugin - no arm scans zsh/plugins/; move it out, or pin it as submodule.<name>.path = zsh/plugins/<name> in .gitmodules
```

`bin/check-patterns` exits 1 with this message, so `make lint` or
`make check-patterns` fails (make reports `Error 1`).

**Cause.** No check reads `zsh/plugins/`, because the pinned plugins there are
third-party code. So anything in it other than a pinned plugin fails the gate,
tracked or not. On a Mac, the usual case is a `.DS_Store` that Finder created
when the folder was opened. This is intended: the gate fails closed rather
than let a file hide where nothing scans it.

**Fix.** Delete the file. Do not allowlist it.

```sh
rm <checkout>/zsh/plugins/.DS_Store
```
