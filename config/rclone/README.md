<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# config/rclone: a template for rclone, never installed

This directory holds a template for configuring [rclone](https://rclone.org) on
a machine that runs this framework. rclone's configuration holds secrets:
remote tokens, API keys and encryption passwords. So the link engine's
exceptions table (`lib/link.sh`) never links this directory into `~/.config`,
and skips `config/restic/` for the same reason. The repository keeps only this
README and `*.example` templates, never a real `rclone.conf`: secrets must not
be committed. `.gitignore` ignores every other file here.

For the full backup setup, rclone and restic together, read
[backup and restore](../../docs/backup-restore.md). This page covers only the
files in this directory.

## Where your real config lives

Because this directory is never linked, your working config is a plain,
unmanaged file that the framework does not touch:

```
~/.config/rclone/rclone.conf     # your real config - NOT a symlink into this repo
```

`~/.config/rclone/` is an ordinary directory (rclone creates it, or you create
it with `mkdir`). It has no relationship to this `config/rclone/` in the
repository. Nothing here is installed, uninstalled or published.

## Set it up on a new machine

```sh
rclone config          # interactive - writes ~/.config/rclone/rclone.conf
# or start from the template and edit by hand. $DOTFILES is the repository
# root, exported by the framework's ~/.zshenv in every zsh:
mkdir -p ~/.config/rclone
cp "$DOTFILES/config/rclone/rclone.conf.example" ~/.config/rclone/rclone.conf
chmod 600 ~/.config/rclone/rclone.conf
```

## Never put a secret in a `*.example` file

The `.example` files are placeholders only. They carry no real remotes, tokens
or passwords, and are safe to commit. Never put a real secret in a file or a
directory named `*.example`: that suffix is deliberately kept tracked, as the
documented template convention, so a real secret there would be committed.
`config/restic/` follows the same pattern; see
[its README](../restic/README.md).
