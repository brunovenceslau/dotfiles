<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# config/restic: templates for restic, never installed

This directory holds templates for configuring
[restic](https://restic.net) backups on a machine that runs this framework. The
installer never links it into `~/.config`, because a restic configuration holds
secrets: the repository location and its password. You copy a template to
`~/.config/restic/`, fill it in there, and that copy stays an ordinary,
untracked file on your machine.

For the full backup walkthrough (rclone remote, first backup, verify, restore,
retention), read [backup and restore](../../docs/backup-restore.md). This page
covers only the files in this directory.

## What is in this directory

| File | Use it for |
| --- | --- |
| [`repo.env.example`](repo.env.example) | One restic repository, used through the `restic-pass-cli` or `restic-op` wrapper. Every value is a secret reference, resolved at call time. The recommended setup. |
| [`restic.env.example`](restic.env.example) | A plain environment file you source yourself, for a machine without a password-manager CLI. Puts the password file path in your shell's environment. |
| `README.md` | This page. |

Nothing else here is tracked: `.gitignore` ignores every other file in
`config/restic/`, and the link engine skips the directory (`lib/link.sh`, the
exceptions table).

## Set up a repository for the wrappers

The wrappers in `zsh/restic.zsh` take a repository name and read
`~/.config/restic/<name>.env` (strictly, `$XDG_CONFIG_HOME/restic/<name>.env`).
Each value in that file is a reference that a password-manager CLI resolves, and
each CLI understands only its own scheme:

| Wrapper | Resolves | Reference form |
| --- | --- | --- |
| `restic-pass-cli` | Proton Pass CLI (`pass-cli run`) | `pass://vault/item/field` |
| `restic-op` | 1Password CLI (`op run`) | `op://vault/item/field` |

1. Create the directory and copy the template under the repository's name. The
   naming convention is `<repository-id>_<remote-id>.env`. `$DOTFILES` is the
   repository root, wherever you cloned it; the framework's `~/.zshenv` exports
   it in every zsh:

   ```sh
   mkdir -p ~/.config/restic
   cp "$DOTFILES/config/restic/repo.env.example" ~/.config/restic/photos_b2.env
   chmod 600 ~/.config/restic/photos_b2.env
   ```

2. Edit the copy and replace each placeholder reference with the path of the
   real item in your password manager, in the scheme of the wrapper you will
   use. Omit the two `AWS_*` lines for a local or sftp repository.

   ```sh
   $EDITOR ~/.config/restic/photos_b2.env
   ```

3. Initialize the repository once, then confirm the wrapper can reach it:

   ```sh
   restic-pass-cli photos_b2 init
   restic-pass-cli photos_b2 snapshots
   ```

   Success: `snapshots` exits 0 and lists no snapshots yet.

A repository you reach through both password managers needs two files, one per
scheme, for example `photos_b2.env` with `pass://` references and
`photos_b2_op.env` with `op://` references.

If a wrapper fails before restic runs:

| Message | Cause |
| --- | --- |
| `usage: pass-cli-backed wrapper <repo> [restic args...]` or `usage: op-backed wrapper <repo> [restic args...]` (exit 2) | No repository name given. |
| `restic: no such repo config: <path>` (exit 1) | No `<name>.env` in `~/.config/restic`. Check the name against `ls ~/.config/restic`. |
| `restic-pass-cli: pass-cli not found` or `restic-op: op not found` (exit 1) | The runner is not installed or not on `PATH`. |

A wrapper that does not exist at all means `restic` was not on `PATH` when the
shell started. Run `./install.sh packages`, then `exec zsh`.

## Use a plain environment file instead

Use this only on a machine without a password-manager CLI. It keeps the
repository password in a file on disk, protected by its mode.

```sh
mkdir -p ~/.config/restic
cp "$DOTFILES/config/restic/restic.env.example" ~/.config/restic/env
chmod 600 ~/.config/restic/env
$EDITOR ~/.config/restic/env      # set RESTIC_REPOSITORY and RESTIC_PASSWORD_FILE
```

Then load it from `~/.config/zsh/.zshrc.local`:

```sh
set -a; source ~/.config/restic/env; set +a
```

In a new shell, `restic snapshots` reads the repository and password from that
environment.

## Never put a secret in a `.example` file

The `.example` files carry placeholders only, and they are tracked on purpose:
they are the documented templates. A real value written into a file or
directory named `*.example` would be committed. Fill in the copies under
`~/.config/restic/`, never the templates here.
