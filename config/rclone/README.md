<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# config/rclone - local-only by design (NEVER linked)

`rclone` (and `restic`) hold **secrets** in their configuration - remote tokens,
API keys, encryption passwords. The link engine's exceptions table therefore
**never links this directory** into `~/.config`: `config/rclone/`
is skipped entirely, alongside `config/restic/`. The repo keeps only this README
and `*.example` templates - never a real `rclone.conf` (secrets MUST
NOT be committed).

## Where your real config lives

Because this directory is never linked, your working config is a **plain,
unmanaged file** that the framework does not touch:

```
~/.config/rclone/rclone.conf     # your real config - NOT a symlink into this repo
```

`~/.config/rclone/` is an ordinary directory (rclone creates it, or `mkdir` it
yourself); it has no relationship to this `config/rclone/` in the repo. Nothing
here is installed, uninstalled, or published.

## Setting it up on a new machine

```sh
rclone config          # interactive - writes ~/.config/rclone/rclone.conf
# or start from the template and edit by hand. $DOTFILES is the repository
# root, exported by the framework's ~/.zshenv in every zsh:
mkdir -p ~/.config/rclone
cp "$DOTFILES/config/rclone/rclone.conf.example" ~/.config/rclone/rclone.conf
chmod 600 ~/.config/rclone/rclone.conf
```

The full backup setup, rclone and restic together, is
[backup and restore](../../docs/backup-restore.md).

The `.example` files are placeholders only - they carry no real remotes, tokens,
or passwords, and are safe to commit. **Never** put a real secret in a file (or a
directory) named `*.example`: that suffix is deliberately kept tracked (it is the
documented template convention), so a real secret there would be committed.
`restic` follows the same pattern - see `config/restic/README.md`.
