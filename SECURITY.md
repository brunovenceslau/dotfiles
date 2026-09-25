<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Security policy

## Reporting a vulnerability

Report privately through GitHub, never in a public issue or pull request:

**<https://github.com/brunovenceslau/dotfiles/security/advisories/new>**

That form opens a private advisory visible only to you and the maintainer. It is
the only reporting channel. If you cannot use it, say so in a public issue
without any detail about the vulnerability and you will be contacted.

Include what you have: the file and line, what an attacker controls, what they
gain, and the shortest way to reproduce it. A diff is welcome but not required.

**Response:** a first reply within seven days, best effort. This repository has
a single maintainer and no on-call rotation. If seven days pass with no reply,
send a reminder through the same form.

**Disclosure:** the fix and the advisory are published together. You are
credited in the advisory unless you ask not to be.

## Supported versions

| Version | Supported |
| --- | --- |
| `main` | Yes |
| The latest release tag | Yes |
| Any earlier tag | No |

The project is pre-1.0 (SemVer `0.y.z`): the public surface is not frozen, and
a break is a MINOR bump, named in the release notes (see
[development, Cutting a release](docs/development.md#cutting-a-release)).
There is no backport branch. A fix lands on `main` and is carried by the next
tag. If you run an older tag, upgrade rather than wait for a patch release.

## What is in scope

A report is in scope when it weakens one of the properties the framework
claims. These are the same surfaces that require a maintainer decision before
any change, listed in
[CONTRIBUTING.md](CONTRIBUTING.md#ask-before-you-build-any-of-these):

- **The plugin supply chain.** The three zsh plugins are submodules pinned to
  exact commits and loaded by a static loader. Anything that lets unpinned or
  unreviewed plugin code reach the startup path is in scope, including a way
  around the neutralized fast-syntax-highlighting theme download.
- **The SSH signing setup.** A way to land an unsigned or wrongly attributed
  commit on `main`.
- **Object checking on fetch.** `transfer`, `fetch` and `receive.fsckObjects`
  are on in the tracked git config, and the upgrade path, the background update
  check and the installer's plugin submodule step each force them on the
  command line, whatever the ambient configuration says. A way to turn any of that off from outside
  the repository is in scope.
- **The git-config scrubbing on the upgrade path and the update check.** The
  `vgit` wrapper in `install.sh` runs the upgrade, and `zsh/update-check.zsh`
  runs its background fetch, with `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM`
  pointed at `/dev/null` and the `GIT_CONFIG_*` environment families removed.
  A way to inject configuration back into either path is in scope.
- **The anti-rollback merge.** `dotfiles-upgrade` merges `--ff-only`. A way to
  make it accept a rewound or diverged history is in scope.
- **The link engine and the manifest.** Overwriting a user file without the
  `.bak` copy, writing outside the paths the installer declares, or making
  `dotfiles-uninstall` remove something it did not create.
- **The startup path.** Getting a subprocess or a network call onto the path to
  the first prompt, in a way `make forkgate` does not catch. The one documented
  exception, the detached background `git fetch` of the update check (see
  [architecture](docs/architecture.md#the-one-sanctioned-background-spawn)), is
  in scope only if it can be made to block the prompt, prompt for input, fetch
  from anywhere but the clone's `origin`, or skip object checking.
- **Secrets.** Anything secret-shaped that is committed, or a way past both
  `make secret-scan` and `make gitleaks`.

## What is out of scope

- **The pinned plugins' own code.** It is upstream's. Report it upstream. A
  report here is in scope only if the pinning or the loader is what lets the
  problem reach you.
- **Third-party tools the framework only integrates with**, such as Homebrew,
  starship, fzf, zoxide, restic and rclone. Report those upstream.
- **A weakness that needs an attacker who already has write access to your
  machine or to this repository.** At that point the framework is not the
  boundary.
- **The contents of your own untracked `.local` files.** They are yours, they
  are never committed, and the framework does not validate them.
- **Missing hardening with no attack behind it.** A suggestion is welcome as an
  ordinary issue or pull request.

`dotfiles-upgrade` does not verify signatures on what it fetches. It is a fetch
plus a fast-forward merge, and it trusts the remote you cloned from. That is a
documented limitation, not a vulnerability.
