<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Documentation

Documentation for the dotfiles framework. The top-level
[`README.md`](../README.md) is the front page: what this is, how to install it,
and the commands you use daily. This directory holds everything deeper.

Each page has one primary reader and one purpose.

## Understand it

| Page | Reader | Covers |
| --- | --- | --- |
| [architecture.md](architecture.md) | Anyone reading the framework | Design goals, repository layout, the link engine and its manifest, the `.local` layer, the interactive startup path, the pinned plugins and their supply chain, the upgrade path, platform differences. |

## Look something up

| Page | Reader | Covers |
| --- | --- | --- |
| [shell-reference.md](shell-reference.md) | A user of the shell | `install.sh` subcommands, lifecycle commands, the restic wrappers, every helper function and alias, commands on `PATH`, key bindings, shell options, environment variables, generated files, `.local` files, config surfaces. |

## Do a task

| Page | Reader | Covers |
| --- | --- | --- |
| [new-mac-host.md](new-mac-host.md) | An operator setting up a machine | Prerequisites, authentication, clone and install, identity and signing, packages, legacy cleanup, verification. |
| [backup-restore.md](backup-restore.md) | An operator running backups | The secret model, rclone and restic setup, the `restic-pass-cli` and `restic-op` wrappers, backup, verify, restore, retention. |
| [troubleshooting.md](troubleshooting.md) | Anyone with a broken shell | Symptom, cause and fix for the messages you are most likely to see. `tests/troubleshooting_messages_test.sh` checks that each quoted message still exists in the code. |

## Change it

| Page | Reader | Covers |
| --- | --- | --- |
| [development.md](development.md) | A maintainer | The quality gates and what each proves, `STRICT=1`, CI, the hard rules, common changes such as adding a config or bumping a plugin pin, and lessons from past reviews. |
| [stacked-prs.md](stacked-prs.md) | A maintainer landing a large change | Why every PR targets `main`, the workflow, re-syncing after a merge, keeping signatures through a rebase. |
