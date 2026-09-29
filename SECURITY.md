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

A report is in scope when it weakens one of the security properties the
framework claims. The authoritative list, with the condition that makes a
report in scope for each property and the file or test that enforces it, is
[Security properties and where they are enforced](docs/architecture.md#security-properties-and-where-they-are-enforced).
In short, the properties are:

- the plugin supply chain: pinned plugins, a static loader and the neutralized
  fast-syntax-highlighting theme download;
- the SSH signing setup, which keeps unsigned or wrongly attributed commits off
  `main`;
- object checking on every fetch after install, forced on the command line
  wherever the framework fetches;
- the git-config scrubbing on the upgrade path and the update check;
- the anti-rollback merge (`--ff-only`);
- the link engine and the manifest;
- the refusal to run as root;
- the startup path, with its one documented background fetch;
- secrets, and the two scanners that keep them out.

A change to any of these needs a maintainer decision before the code is written;
see
[CONTRIBUTING.md](CONTRIBUTING.md#ask-before-you-build-any-of-these).

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
