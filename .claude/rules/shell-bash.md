---
description: Bash conventions and the bash 3.2 constraint for install.sh, lib/, bin/ and tests/
paths:
  - "install.sh"
  - "lib/**"
  - "bin/**"
  - "tests/**"
---

<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Bash rules for the dotfiles framework

These apply to `install.sh`, `lib/*.sh`, `bin/*` and `tests/*.sh` in the
`dotfiles` repository.

## Target bash 3.2 in install.sh and lib/

macOS ships `/bin/bash` 3.2 and the installer runs under it. In `install.sh` and
`lib/`, do not use associative arrays, `mapfile`, or `${var,,}`.

`bin/` is exempt. Those tools run only on a provisioned host or on a CI runner,
where a modern bash is present.

`make check-patterns` is the gate for those three. It flags
`declare -A`/`typeset -A`/`local -A`, `mapfile`/`readarray` and
`${var,,}`/`${var^^}` in `install.sh` and `lib/*.sh`, on any host, including
`${1,,}` on a positional and `${!v,,}` through an indirection. It tests code
rather than raw lines, so a comment that states the rule is not a violation,
whether it owns the line or trails real code (after a `#` or a `;#`).

`make lint` also parses `install.sh`, `lib/*.sh` and `tests/*.sh` with an
explicit `/bin/bash -n`, which on the macOS CI legs is the real 3.2. Do not read
that as a backstop for the three above: `declare -A` and `mapfile` are ordinary
command invocations, and `${var,,}` fails when it is expanded, so no bash of any
version reports a PARSE error for them. What that pass does catch is the syntax
3.2 genuinely cannot parse, such as `;;&` or `|&`. `bin/` is in neither list.

## Write every script the same way

- Open with `set -euo pipefail`.
- Report through the `log` and `warn` helpers the caller defines. A `lib/` file
  does not define them; it states in its header that the caller must.
- Prefer a guard over a comment warning about the danger.
- Stay shellcheck-clean. `make lint` runs shellcheck over `install.sh`, `lib/`
  and `bin/`. `tests/` is not on that surface.

## Never hardcode the Homebrew prefix

The prefix is `/opt/homebrew` on Apple Silicon and `/usr/local` on Intel. Detect
it by directory existence. Do not shell out to `brew shellenv`.

`make check-patterns` gates both halves. It flags a `/opt/homebrew` unless
`/usr/local` is the ADJACENT word, because two prefixes side by side is what a
detection loop or a candidate list looks like, and anything looser exempts by
coincidence: `PATH="/opt/homebrew/bin:/usr/local/bin"` names both inside one word,
and `[ -d /usr/local/go ] && P=/opt/homebrew` names both on one line while the
`/usr/local` is about Go. Keep the pair on one line. It also flags `brew shellenv`
and a bare `brew --prefix`; `brew --prefix <formula>` asks a different question,
and every other `brew` call, such as `brew bundle`, is untouched. A lone
`/usr/local` is never flagged: it is a generic FHS path with non-Homebrew uses.
`config/gnupg/gpg-agent.conf` is the one allowlisted file, because gpg-agent.conf
has no variable expansion and its pinentry path must be absolute.

Route every architecture check through the `is-arm64` and `is-amd64` helpers in
`lib/os.sh`. An ad-hoc `uname -m` outside `lib/os.sh` fails
`make check-patterns`.

## Know what the scanner does not read

`bin/check-patterns` scans `install.sh`, `lib/`, `bin/`, `zsh/`, `config/`,
`packages/`, `security/` and `home/`. Neither `security/` nor `home/` exists
today; an absent root is skipped, not an error. `tests/` is NOT on that surface and cannot
join it: `tests/check_patterns_test.sh` plants real `curl|sh` and `wget|bash`
fixtures, and `tests/os_test.sh` runs `uname -m` legitimately, so scanning
`tests/` would make the gate fail on its own suite. Under `tests/` every rule on
this page is discipline, not a gate.

## Leave the user's .local files alone

`lib/uninstall.sh` is manifest-driven: it removes only links the manifest
records and that still point into the repo, restores any `*.bak`, and touches
nothing else. `--purge` additionally clears generated state and cache, but never
a `.local` file. Those are the user's machine-local layer and the framework does
not own them.

## Treat an install.sh subcommand name as an ABI

The PREVIOUS release's installer invokes a subcommand by name on the NEW tree
during an upgrade. Deleting an arm sends that installer to the `*)` branch,
which exits 2 and reports a failed upgrade. Retire an arm by making it a no-op
instead, the way `reseed-settings` does.
