<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Manage this host's signing key

Recipes for the git identity and SSH signing key of a host that already runs
the framework: one problem per section, each with the commands and a check
that proves it worked. The exact rule the identity step follows is in
[`install.sh identity`](shell-reference.md#installsh-identity); why the key
is static and why retiring a key is not revoking it is in
[the host's signing identity](architecture.md#the-hosts-signing-identity).
Setting up a new mac is in
[provision a new mac host](new-mac-host.md#5-set-identity-and-signing).

The commands assume the checkout at `~/.config/dotfiles`, the key at
`~/.ssh/id_signing`, and the allowed-signers file at its default path,
`~/.config/git/allowed_signers`.

- [Check which identity and key git uses](#check-which-identity-and-key-git-uses)
- [List a host's key in the allowed-signers file](#list-a-hosts-key-in-the-allowed-signers-file)
- [Add your name after an upgrade](#add-your-name-after-an-upgrade)
- [Rotate the signing key](#rotate-the-signing-key)
- [Revoke a lost or compromised key](#revoke-a-lost-or-compromised-key)
- [Keep a host from signing](#keep-a-host-from-signing)
- [Fix commits made with the wrong identity](#fix-commits-made-with-the-wrong-identity)
- [What the identity step prints when it works](#what-the-identity-step-prints-when-it-works)

## Check which identity and key git uses

`install.sh doctor` reads what the identity step reads (git config, the
allowed-signers and revocation files, the public keys in the ssh-agent) and
prints only what needs action. A host in good shape prints nothing:

```sh
cd ~/.config/dotfiles && ./install.sh doctor; echo "exit=$?"
```

`exit=0` with no other line means the identity and signing are in place, or
the host opted out of signing in `config.local`. Each problem is one line
naming the cause, most with the fix. `--verbose` prints every check, with
each value and the file it comes from:

```sh
./install.sh doctor --verbose
```

To ask git directly, read the values from outside any repository, the way a
commit outside one sees them:

```sh
git -C ~ config --show-origin --get user.email
git -C ~ config --show-origin --get user.signingkey
```

Each line names `~/.config/git/config.local`. Then prove a real signature, in
a scratch repository so nothing lands in a real one (a local commit in the
framework's checkout would block the next `dotfiles-upgrade`):

```sh
cd "$(mktemp -d)" && git init -q && git commit -q --allow-empty -m "signing check"
git log -1 --format='%G? %GS %GF'
ssh-add -l
```

Expect `G`, your email, and a fingerprint that `ssh-add -l` lists. A `G`
alone is not enough: git does not tie the signer to the committer email.

> **Warning:** never set identity or signing with `git config --global`. With
> the framework, it writes `~/.config/git/config`, or `~/.gitconfig` when that
> file exists, not `config.local`. The identity step then reports the value as
> set in a file outside `config.local`, and `--rotate` refuses to touch it.
> Use `./install.sh identity`, or
> `git config --file ~/.config/git/config.local`.

## List a host's key in the allowed-signers file

The allowed-signers file is the trust root: the identity step picks this
host's key from it, and git verifies signatures against it. Each line is
`<email> [options] <keytype> <base64>`. Append this host's public key, for
the `git` namespace only:

```sh
mkdir -p ~/.config/git
printf '%s namespaces="git" %s\n' "you@example.com" \
  "$(cut -d' ' -f1,2 ~/.ssh/id_signing.pub)" >> ~/.config/git/allowed_signers
grep -F "$(cut -d' ' -f2 ~/.ssh/id_signing.pub)" ~/.config/git/allowed_signers
```

The `grep` prints the new line. A line without `namespaces` counts too; with
it, the key is trusted for git signatures and nothing else.

The framework does not sync this file between hosts. A host verifies only the
signatures whose keys its own copy lists, so copy each host's line into the
file on every other host that should verify its commits.

A line you paste is trusted as it is. Before you add one that came from
another host, compare its fingerprint with the one that host prints for its
own key, read over a channel other than the one the line came through:

```sh
ssh-keygen -lf ~/.ssh/id_signing.pub      # on the host that owns the key
printf '%s\n' "ssh-ed25519 AAAA..." | ssh-keygen -lf -   # the pasted key
```

## Add your name after an upgrade

On a host where `dotfiles-upgrade` (or `./install.sh link`) set the identity,
everything is in place except `user.name`, which the step never writes: the
name is yours to choose. Until it is set, git refuses every commit, since the
tracked config sets `user.useConfigOnly = true`, and every `link` and
`dotfiles-upgrade` prints a `user.name is not set` line. If this
prints your name, there is nothing to do:

```sh
git -C ~ config --get user.name
```

Otherwise, set it once:

```sh
cd ~/.config/dotfiles && ./install.sh identity --name "Your Name"
git -C ~ config --show-origin --get user.name
```

A different `user.name` already set anywhere is kept: the step reports it as
`already set to a different value` and writes nothing. Change it in the file
the second command names.

## Rotate the signing key

Add the new key before you remove the old one, so the host can always sign.

1. Generate the new key and load it into the agent:

   ```sh
   ssh-keygen -t ed25519 -C "$(hostname -s) signing" -f ~/.ssh/id_signing_new
   ssh-add --apple-use-keychain ~/.ssh/id_signing_new
   ssh-add -l
   ```

   `--apple-use-keychain` is macOS only: it keeps the passphrase in the
   macOS Keychain. No test in this repository runs it. Elsewhere, drop the
   flag.

2. List it in the allowed-signers file next to the old one, as in
   [list a host's key](#list-a-hosts-key-in-the-allowed-signers-file), and
   register it on GitHub as a signing key:

   ```sh
   gh auth refresh -h github.com -s admin:ssh_signing_key
   gh ssh-key add ~/.ssh/id_signing_new.pub --type signing --title "$(hostname -s) signing"
   gh auth refresh -h github.com --remove-scopes admin:ssh_signing_key
   ```

   The last command drops the extra scope again once the key is added. No
   test in this repository runs these; the flags are the ones `gh --help`
   documents.

3. Retire the old line with a `valid-before` date that has already passed
   when you write it: `20260101` below is an example, so use a date before
   today. Without a `Z` suffix the date is local time. The old line becomes:

   ```text
   you@example.com namespaces="git",valid-before="20260101" ssh-ed25519 AAAA...old
   ```

4. Rotate. The step replaces `user.signingkey` only when the old key no
   longer verifies for your email and exactly one agent key does:

   ```sh
   cd ~/.config/dotfiles && ./install.sh identity --rotate
   ```

   It prints the old and the new fingerprint, and why the old key no
   longer verifies (here, `line <n>: expired`):

   ```text
   install: identity: rotated user.signingkey for <email>: <old fingerprint> -> <new fingerprint> (old key: <reason>)
   ```

5. Check it as in
   [check which identity and key git uses](#check-which-identity-and-key-git-uses).

Then, on GitHub, delete the old signing key (Settings, SSH and GPG keys).
GitHub records a commit's verification when it is pushed and does not
verify it again, so the commits it already shows as Verified stay Verified
(GitHub docs, "About commit signature verification", read 2026-09-23).
Update the allowed-signers file on every host that verifies this one's
commits.

`valid-before` is routine retirement only. A key that is lost or
compromised needs the next recipe.

## Revoke a lost or compromised key

On a host whose revocation file lists a key, git reports a signature by that
key as bad, whatever date the commit claims. That is the intent: whoever
holds the key can no longer sign as you there. The identity step reads the
same revocation file, so it never picks a revoked key.

1. Create the revocation file before git is told about it. A
   `gpg.ssh.revocationFile` that names an unreadable file makes every writing
   mode of the identity step refuse:

   ```sh
   touch ~/.config/git/revoked_signers
   git config --file ~/.config/git/config.local gpg.ssh.revocationFile ~/.config/git/revoked_signers
   ```

2. Append the old public key, without its comment:

   ```sh
   cut -d' ' -f1,2 ~/.ssh/id_signing_old.pub >> ~/.config/git/revoked_signers
   cat ~/.config/git/revoked_signers
   ```

   If the `.pub` file is gone with the key, copy the `<keytype> <base64>`
   pair from the key's line in the allowed-signers file instead.

3. Remove it from the agent and from GitHub:

   ```sh
   ssh-add -d ~/.ssh/id_signing_old.pub
   ```

   On GitHub, delete it under Settings, SSH and GPG keys.

4. Load the replacement key and list it, as steps 1 and 2 of
   [rotate the signing key](#rotate-the-signing-key) show, then rotate. A
   revoked key counts as one that no longer verifies:

   ```sh
   cd ~/.config/dotfiles && ./install.sh identity --rotate
   ./install.sh doctor
   ```

   The rotation line ends in `(old key: revoked by gpg.ssh.revocationFile)`,
   and `doctor` prints nothing.

> **Warning:** do this on every host that verifies this host's commits. Each
> host reads only its own revocation file.

The difference between retiring and revoking is explained in
[rotating the signing key](architecture.md#rotating-the-signing-key).

## Keep a host from signing

A host can choose not to sign. The tracked git config turns commit signing
on, so without a signing key every commit fails, with
`fatal: either user.signingkey or gpg.ssh.defaultKeyCommand needs to be configured`.
A host that must commit without a key opts out with an explicit `false` in
`config.local`, the one file that opts a host out. git reads it after the
tracked `true`, so it wins:

```sh
git config --file ~/.config/git/config.local commit.gpgsign false
```

From then on `install`, `link` and every `dotfiles-upgrade` leave the host's
signing alone: the automatic identity step writes nothing and prints nothing.
`./install.sh doctor` still reports a missing name or email, and reports the
signing problems only as notes; `--verbose` says why:

```sh
./install.sh doctor --verbose | grep 'commit.gpgsign = false from'
```

```text
install: doctor: values: commit.gpgsign = false from <origin>: respected as this host's opt-out; the automatic step stays quiet and writes nothing
```

`<origin>` is where git read the `false`: `file:` and the path of
`config.local`. A `false` in any other file, or a `tag.gpgsign = true` beside
it, is not an opt-out, and `doctor` reports what it finds. The full rule
is in
[opting a host out of signing](shell-reference.md#opting-a-host-out-of-signing).

To sign again, remove the `false` and let the step fill in the rest. Run
the three lines together: between the first and the second, the host has
signing on and, if it had no key, cannot commit.

```sh
git config --file ~/.config/git/config.local --unset commit.gpgsign
cd ~/.config/dotfiles && ./install.sh identity
./install.sh doctor
```

A `commit.gpgsign = false` in the checkout's own `config/git/config.local`, a
layout older installs used, still turns signing off, since the tracked config
includes that file. It is not an opt-out, though: it is the host's exception,
which `install.sh doctor` reports as a problem. Move it to
`~/.config/git/config.local` to opt out.

## Fix commits made with the wrong identity

Rewrite only commits you have not pushed. The `main` ruleset refuses a force
push to `main`, so a pushed commit there stays as it is.

First make sure git now uses the right identity, as in
[check which identity and key git uses](#check-which-identity-and-key-git-uses).
Then, for the last commit:

```sh
git commit --amend --no-edit --reset-author -S
git log -1 --format='%an <%ae> %G? %GS'
```

For every unpushed commit after `<base>`:

```sh
git -c commit.gpgsign=true rebase -r --exec 'git commit --amend --no-edit --reset-author' <base>
git log --format='%h %an <%ae> %G? %GS' <base>..
```

Each line shows your name and email, `G`, and your email as the signer.
`--reset-author` also sets the author date to now. On a branch of your own
that you already pushed, publish the rewrite with
`git push --force-with-lease`.

## What the identity step prints when it works

`./install.sh identity`, and the automatic step in `install`, `link` and
`dotfiles-upgrade`, print one or more of these when they succeed:

```text
install: identity: wrote <keys> to <path>
install: identity: already configured for <email> (<fingerprint>)
install: identity: user.name is not set - run: <path to install.sh> identity --name "<full name>"
install: identity: <key> is false (<origin>) - kept as this host's exception, so it stays off
install: identity: tag.gpgsign is left unset while commit.gpgsign is false (this host opted out of signing)
install: identity: rotated user.signingkey for <email>: <old fingerprint> -> <new fingerprint> (old key: <reason>)
install: identity:   it was: <old value>
```

`wrote` lists the keys it added to `config.local`. The first time it
changes a `config.local` that already exists, it keeps the old content in
`config.local.bak`, and never replaces that `.bak` afterwards.
`already configured` means every value was in place. The `user.name` line
follows a successful run on a host with no name yet, and is the one line
`link` and `dotfiles-upgrade` print while the name is all that is missing;
see [add your name](#add-your-name-after-an-upgrade). Its `<full name>` is
this account's full name when the system records one (the GECOS field git
itself would read), and `Full Name` otherwise: a suggestion to check, never
a value the step writes. The `false` lines name a setting the step left
alone on purpose, as
[`install.sh identity`](shell-reference.md#installsh-identity) describes.
The rotation line is followed by the old value of `user.signingkey`. A
message that ends in `writing nothing` or `refusing` is in
[troubleshooting](troubleshooting.md#the-installer-did-not-set-the-git-identity).
