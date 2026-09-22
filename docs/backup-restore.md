<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Backup and restore

Back up a mac with [restic](https://restic.net) (deduplicated, encrypted
snapshots) to a cloud remote reached through [rclone](https://rclone.org).

The framework does not run backups for you. It provides two things: the
convention that keeps backup secrets off the repository, and two shell wrappers
that resolve those secrets at call time.

## The model

`config/restic/` and `config/rclone/` are never linked into `~/.config`. The
repository tracks only a README and `*.example` templates. Your real
configuration is an ordinary, unmanaged file on the machine.

Each restic repository gets one env file at
`$XDG_CONFIG_HOME/restic/<name>.env`. Every value in it is a `pass://`
reference, never a literal secret. A secret runner resolves the references and
execs restic with the results in its environment only. Nothing is written to disk
in the clear, and nothing is exported into your shell.

Two rules follow from this:

- **Run restic on the mac.** Never carry the repository password or the remote
  token into a sandbox, a container, or another machine.
- **Treat mounted and cloud-synced folders as untrusted.** Anyone who can write
  to such a folder can place files there, so never point auto-executing tooling
  (direnv `.envrc`, git `core.hooksPath`, editor project autoload) at a
  restic-mounted or cloud-synced path.

## 1. Install the tools

`restic`, `rclone` and `gnupg` are in the tracked Brewfile, so
`./install.sh packages` already installed them. Confirm:

```sh
restic version && rclone version
```

The secret runner is not in the tracked Brewfile, because which one you use is a
per-host choice. Install `pass-cli` or the 1Password CLI (`op`) yourself, and add
it to `packages/Brewfile.local` so a re-provision keeps it.

## 2. Configure the rclone remote

`rclone config` writes `~/.config/rclone/rclone.conf`. That path is an ordinary
file the framework never touches:

```sh
rclone config                 # interactive: create a remote, for example "backup"
chmod 600 ~/.config/rclone/rclone.conf
rclone listremotes            # expect: backup:
```

## 3. Configure a restic repository

Copy the per-repository template and fill in references:

```sh
mkdir -p ~/.config/restic
cp ~/.config/dotfiles/config/restic/repo.env.example ~/.config/restic/photos_b2.env
$EDITOR ~/.config/restic/photos_b2.env
chmod 600 ~/.config/restic/photos_b2.env
```

The file names its values by reference:

```sh
AWS_ACCESS_KEY_ID="pass://vault/BACKUP/EXAMPLE_ACCESS_KEY_ID"
AWS_SECRET_ACCESS_KEY="pass://vault/BACKUP/EXAMPLE_ACCESS_KEY_SECRET"
RESTIC_REPOSITORY="pass://vault/BACKUP/EXAMPLE_REPOSITORY"
RESTIC_PASSWORD="pass://vault/BACKUP/EXAMPLE_PASSWORD"
```

Omit the two AWS values for a local or sftp repository. A repository reached
through rclone uses `rclone:<remote>:<bucket>/<path>` as its location, and a
local path may be given literally.

Naming convention: `<repository-id>_<remote-id>.env`, so one repository backed up
to two places reads as two files that differ only in the remote half.

Never put a real secret in a file named `*.example`. That suffix stays tracked by
design.

## 4. Run restic through a wrapper

The wrappers take the repository name (the `.env` basename) followed by ordinary
restic arguments. Tab completion offers the names you have.

```sh
restic-pass-cli photos_b2 init         # once per repository
restic-pass-cli photos_b2 snapshots
restic-op       photos_b2 snapshots    # the same, through the 1Password CLI
```

The wrappers are defined only when `restic` is on `PATH`, and each checks for its
own runner before doing anything.

## 5. Take a backup

Back up the home directory, excluding large rebuildable stores:

```sh
restic-pass-cli photos_b2 backup "$HOME" \
  --exclude "$HOME/.cache" \
  --exclude "$HOME/Library/Caches" \
  --exclude "$HOME/.config/dotfiles" \
  --exclude-caches \
  --exclude "*/node_modules"
```

`~/.config/dotfiles` is excluded because it is a git clone: re-clone it instead
of restoring it. `--exclude-caches` skips directories tagged with `CACHEDIR.TAG`.

Once the exclude set grows, keep it in a file and pass
`--exclude-file ~/.config/restic/excludes`.

Each run prints the new snapshot's short ID. Repeated runs are fast, because only
changed data is stored.

## 6. Verify

A backup you never verify is a backup you do not have.

| Command | What it tells you |
| --- | --- |
| `restic-pass-cli <repo> snapshots` | Snapshot IDs, host, time and paths. |
| `restic-pass-cli <repo> stats` | Repository size and deduplication ratio. |
| `restic-pass-cli <repo> check` | Structural integrity of the metadata. |
| `restic-pass-cli <repo> check --read-data` | Re-reads and re-hashes every blob. Slow, and the only full proof. |

Run `check` on a schedule, and `check --read-data` occasionally.

## 7. Restore

Never restore over live data blindly. Restore to a fresh directory and copy out
what you need.

```sh
# A whole snapshot:
restic-pass-cli photos_b2 restore latest --target /tmp/restore

# One path from the latest snapshot:
restic-pass-cli photos_b2 restore latest --target /tmp/restore --include "$HOME/Documents"

# A specific snapshot:
restic-pass-cli photos_b2 restore ab12cd34 --target /tmp/restore

# Browse interactively, then copy out. Ctrl-C unmounts.
mkdir -p /tmp/backup-mount
restic-pass-cli photos_b2 mount /tmp/backup-mount
```

The mount is a backup folder, so the untrusted-folder rule above applies to it.

## 8. Retention

```sh
restic-pass-cli photos_b2 forget \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 3 --prune
```

`forget` drops snapshots outside the policy. `--prune` reclaims the data they
held. Run it after backups, not instead of them.

## 9. Scheduling (optional)

The framework ships no scheduler. If you add one (a launchd agent, a cron entry,
a wrapper script), keep the secret handling identical: the job calls the same
wrapper, on the mac, and resolves references at call time. Do not move any
credential off the host, and do not give the scheduler a mounted or cloud-synced
working directory.

## Alternative: a plain env file

If you do not use a secret runner, restic also reads its settings from the plain
environment. Copy `config/restic/restic.env.example` to `~/.config/restic/env`,
fill in `RESTIC_REPOSITORY` and `RESTIC_PASSWORD_FILE`, `chmod 600` it, and load
it from your `.local` layer:

```sh
# in ~/.config/zsh/.zshrc.local
set -a; source ~/.config/restic/env; set +a
```

Prefer `RESTIC_PASSWORD_FILE` over `RESTIC_PASSWORD`, so the password never sits
in the process environment. This path puts the repository password on disk in
plain text, which is why the wrappers exist.
