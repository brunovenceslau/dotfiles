<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

## What this changes and why

<!-- One paragraph. What behaviour differs after this merges, and which
constraint or defect made the change necessary. -->

## How it was verified

<!-- Name the test that would have caught the defect, or say why the change is
not testable. "The gates are green" is not a verification. -->

## Checklist

- [ ] `make lint` is green.
- [ ] `make local-ci STRICT=1` was run, not just `make local-ci`. A run without
      `STRICT=1` exits 0 on a gate whose tool is missing.
- [ ] Suites that skipped are named below, with the tool each one wanted. Some
      suites skip and still exit 0 even under `STRICT=1`, so a green run is not
      a claim of coverage.
- [ ] Every commit is signed, and the subject is a Conventional Commit of 72
      characters or fewer. No trailers.
- [ ] This pull request targets `main`. If it is stacked, the body says
      "stacked on #N, review only the last K commits".
- [ ] Documentation that describes changed behaviour is updated in the same
      commit, and no claim in it is unsupported by the tree.
- [ ] No em dash anywhere in the diff.

### Suites that skipped

<!-- "none", or one line per suite: the suite name and the missing tool. -->

none

## Ask-first surfaces

- [ ] This change touches **none** of the surfaces below.

If it touches any of them, tick the ones it touches and link the issue where
the maintainer agreed to the approach. A pull request that changes one of these
without that agreement is closed on the question, not on the code.

- [ ] The plugin pins, the `.gitmodules` entries, or the static plugin loader.
- [ ] The SSH signing setup.
- [ ] `fsckObjects` on any fetch, including the detached update sentinel.
- [ ] The `vgit` wrapper or anything else on the `install.sh` upgrade path.
- [ ] The neutralized fast-syntax-highlighting runtime download.
- [ ] A link convention or the exceptions table in `lib/link.sh`.
- [ ] A new submodule or any new binary dependency.
- [ ] An `install.sh` subcommand name. Subcommands are a cross-version
      interface and are retired as no-ops, never deleted.
