#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for config/ghostty/ - the host-only Ghostty terminal
# that coexists with Alacritty. Ghostty is a macOS GUI (no binary on CI), so its
# key=value config is validated STATICALLY: syntax (comments only on their own
# line), the per-host config.local include, the referenced themes, and the
# .local/.example gitignore split. Not part of the shellcheck surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
gd="$repo_root/config/ghostty"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ck() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail "$1: got [$2] want [$3]"; fi; }

# --- the base, the example, and both referenced themes exist
for f in config config.local.example themes/ipe-amarelo themes/gruvbox-ipe-light; do
  [ -f "$gd/$f" ] || fail "config/ghostty/$f is missing"
done
pass=$((pass + 1))

# --- config.local is gitignored, config.local.example is NOT - a
# broken negation would let a host's .local get committed.
git -C "$repo_root" check-ignore -q config/ghostty/config.local \
  || fail "config/ghostty/config.local is NOT gitignored"
if git -C "$repo_root" check-ignore -q config/ghostty/config.local.example; then
  fail "config/ghostty/config.local.example IS gitignored - the .example must stay tracked"
fi
pass=$((pass + 2))

# --- the per-host config.local is included LAST via
# an OPTIONAL config-file, so it wins (Ghostty processes config-file at the end);
# the base selects a theme that resolves to a real themes/ file.
grep -Eq '^config-file = \?config\.local$' "$gd/config" \
  || fail "config/ghostty/config lost its optional per-host include (config-file = ?config.local)"
grep -Eq '^theme = .*ipe-amarelo' "$gd/config" \
  || fail "config/ghostty/config no longer selects the ipe-amarelo theme"
pass=$((pass + 2))

# --- our custom $ZDOTDIR breaks Ghostty's auto shell integration,
# so the config disables it and zsh/zshrc sources it MANUALLY behind a guard. Pin
# all three halves - losing any leaves ssh-terminfo inert (the "missing terminal"
# bug): (1) auto-injection off, (2) the manual source, (3) the ssh-* features
# armed. #3 matters because `shell-integration = none` makes Ghostty fill
# $GHOSTTY_SHELL_FEATURES from its defaults and IGNORE the config's
# shell-integration-features line, so the wrapper is armed only if zsh/zshrc
# appends ssh-env/ssh-terminfo to $GHOSTTY_SHELL_FEATURES itself.
grep -Eq '^shell-integration = none$' "$gd/config" \
  || fail "config/ghostty/config lost 'shell-integration = none' (auto-injection would fight our ZDOTDIR)"
grep -q 'GHOSTTY_RESOURCES_DIR' "$repo_root/zsh/zshrc" \
  || fail "zsh/zshrc no longer sources the Ghostty shell integration (ssh-terminfo would be inert)"
grep -Eq 'GHOSTTY_SHELL_FEATURES=.*ssh-terminfo' "$repo_root/zsh/zshrc" \
  || fail "zsh/zshrc no longer arms ssh-env/ssh-terminfo in GHOSTTY_SHELL_FEATURES (under shell-integration=none Ghostty drops them, so the ssh wrapper never installs the terminfo)"
pass=$((pass + 3))

# --- Ghostty syntax: a comment is ONLY valid on its own line; a trailing "# ..."
# after a value is swallowed into the value. Assert no active line carries an
# inline comment. Hex colours (palette = N=#rrggbb) are values, not comments - the
# inline-comment marker is a SPACE before '#'. Check the base and both themes.
for f in config themes/ipe-amarelo themes/gruvbox-ipe-light; do
  if grep -nE '^[[:space:]]*[^#[:space:]].* #' "$gd/$f"; then
    fail "config/ghostty/$f has an inline comment (Ghostty allows whole-line comments only)"
  fi
done
pass=$((pass + 1))

# --- each theme sets a background and exactly 16 palette entries.
for t in ipe-amarelo gruvbox-ipe-light; do
  ck "theme $t defines 16 palette colours" "$(grep -cE '^palette = [0-9]+=' "$gd/themes/$t")" "16"
  grep -q '^background = ' "$gd/themes/$t" || fail "theme $t has no background"
done

# --- the example is a placeholder template: no absolute home paths / secrets.
! grep -q '/Users/\|/home/' "$gd/config.local.example" \
  || fail "config/ghostty/config.local.example embeds an absolute home path"
pass=$((pass + 1))

echo "PASS: ghostty_test ($pass assertions)"
