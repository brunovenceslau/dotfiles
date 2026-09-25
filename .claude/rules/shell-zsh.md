---
description: Zsh conventions and the no-fork startup-path rule for everything under zsh/
paths:
  - "zsh/**"
---

<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Zsh rules for the dotfiles framework

These apply to every file under `zsh/` in the `dotfiles` repository.

## Keep the startup path free of subprocesses and network

`zsh/zshrc` and everything it sources run on every interactive shell, so a fork
there is a cost the user pays on every prompt.

- Guard each optional tool with `(( $+commands[<tool>] ))`. That is a builtin
  lookup against the command hash table and forks nothing.
- Never write `eval "$(<tool> init zsh)"`. `install.sh` runs `<tool> init zsh`
  once at install time and caches the output under `$XDG_CACHE_HOME/zsh`. The
  zshrc sources that cache, guarded on the file existing. starship and zoxide
  (`<tool> init zsh`) and canga (`canga completion zsh`) all work this way. It
  is the house pattern, not a workaround.
- `make forkgate` (`bin/startup-fork-gate`) fails the build when an external
  binary is invoked during `zsh -i -c exit`. It is a blocking gate. Do not skip
  it.

When you add a cached init, wire both halves in the same change. Generating a
cache that nothing sources, or sourcing a cache that nothing generates, both
look green and leave the feature dead.

## Never hardcode the Homebrew prefix

The prefix is `/opt/homebrew` on Apple Silicon and `/usr/local` on Intel. Detect
it by directory existence, with no `brew shellenv` subprocess at startup.
Architecture checks go through the `is-arm64` and `is-amd64` helpers in
`lib/os.sh`.

`make check-patterns` flags a `/opt/homebrew` unless `/usr/local` is the ADJACENT
word, and flags `brew shellenv` and a bare `brew --prefix`. Keep both prefixes of
a candidate list side by side on ONE line, the way `zsh/zshrc`'s prefix loop and
`zsh/fzf.zsh`'s fzf-shell list do: the pair is what marks the site as detection
rather than a hardcode.

## Style

- Keep functions small. Declare variables `local`.
- Send errors to stderr and return a non-zero code.
- Name user-facing commands in `kebab-case`, such as `dotfiles-upgrade`.
  `go_test` and `go_test_cover` are the legacy exceptions, kept under the names
  users already type; do not add more.
- Name internal helpers in `snake_case`.
- The user-facing lifecycle commands are zsh functions in `zsh/functions.zsh`,
  not files in `bin/`. They are thin wrappers over `install.sh`, so the logic
  lives once and is unit-tested there.
