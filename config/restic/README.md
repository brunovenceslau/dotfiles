<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# config/restic - local-only by design (NEVER linked)

`restic` is configured through **environment variables**, not a config file in
`~/.config/restic`. Its repository location and password are secrets, so - exactly
like `rclone` - the link engine's exceptions table **never links this directory**
into `~/.config`. The repo keeps only this README and a
`*.example` env templates - never a real password or repository URL: secrets
MUST NOT be committed.

## Where your real config lives

restic reads its settings from the environment (or files those point at); nothing
under this repo dir is installed, linked, uninstalled, or published:

```
RESTIC_REPOSITORY       # e.g. rclone:remote:bucket/path  or  /mnt/backups
RESTIC_PASSWORD_FILE    # path to a file holding the repo password (0600)
```

Keep these in a machine-local, untracked place - your shell's `*.local` layer
(`~/.config/zsh/*.local`, sourced by the framework), a `~/.config/restic/env`
file you source by hand, or a secret manager. Never in the repo.

## The per-repository env files (`restic-pass-cli` / `restic-op`)

`zsh/restic.zsh` defines two wrappers that take a repository NAME and resolve its
secrets at call time:

```sh
restic-pass-cli photos_b2 snapshots     # pass-cli resolves the references
restic-op       photos_b2 snapshots     # same, via the 1Password CLI
```

Each name maps to `$XDG_CONFIG_HOME/restic/<name>.env`, copied from
[`repo.env.example`](repo.env.example). Every value in those files is a
`pass://` REFERENCE, never a literal secret - the runner resolves them into
restic's own environment and nowhere else. Tab completion offers whatever
`*.env` files you have.

## Setting it up on a new machine

```sh
cp config/restic/restic.env.example ~/.config/restic/env   # unmanaged, local-only
$EDITOR ~/.config/restic/env                                # fill in real values
chmod 600 ~/.config/restic/env
# then, in your zsh .local layer:  set -a; source ~/.config/restic/env; set +a
```

The `.example` file is a placeholder only - it carries no real repository, remote,
or password, and is safe to commit. **Never** put a real secret in a file (or a
directory) named `*.example`: that suffix is deliberately kept tracked (it is the
documented template convention), so a real secret there would be committed.
