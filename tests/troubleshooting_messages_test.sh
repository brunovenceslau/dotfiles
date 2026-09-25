#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Doc-sync test: docs/troubleshooting.md is keyed to the exact text the
# framework prints, so a reworded message silently strands its section. Every
# message the page quotes must still exist in the code that prints it
# (install.sh, lib/, zsh/).
#
# What counts as a quoted message:
#   * a line inside a fenced block that starts with `install: ` or `dotfiles: `
#     (the `install: ` prefix is added by install.sh's log/warn, so it is dropped);
#   * a backtick span that starts with one of the framework's message prefixes
#     (`upgrade: `, `link: `, `packages: `, `uninstall: `, `one or more links`,
#     `updates are available`, `no successful update check`).
# Placeholders (`<path>`, `...`, a number such as the 30 in "30 days") stand for
# values the code interpolates, so each message is split at them and every
# literal fragment of 8 or more characters must appear verbatim in the code.
#
# Bash 3.2 compatible (the macOS CI legs run tests under /bin/bash).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
doc="$repo_root/docs/troubleshooting.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$doc" ] || fail "docs/troubleshooting.md not found"

work="$(mktemp -d "${TMPDIR:-/tmp}/troubleshooting_messages_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The code that prints the messages, flattened into one searchable file.
cat "$repo_root/install.sh" "$repo_root"/lib/*.sh "$repo_root"/zsh/zshrc "$repo_root"/zsh/*.zsh > "$work/code"

# 1. Fenced-block lines.
awk '/^```/ { inblock = !inblock; next }
     inblock && /^(install|dotfiles): / { sub(/^install: /, ""); print }' "$doc" > "$work/msgs"
# 2. Backtick spans with a message prefix (one span per line of output).
grep -oE '`[^`]+`' "$doc" | sed 's/^`//; s/`$//' \
  | grep -E '^(upgrade: |link: |packages: |uninstall: |one or more links|updates are available|no successful update check)' \
  >> "$work/msgs" || true

count="$(grep -c . "$work/msgs" || true)"
[ "$count" -ge 15 ] || fail "extracted only $count messages from the page (extraction rot?)"

checked=0
while IFS= read -r msg; do
  [ -n "$msg" ] || continue
  # Split at placeholders: <...>, a literal "...", and digit runs.
  # awk, not sed: BSD sed does not turn \n in a replacement into a newline.
  printf '%s\n' "$msg" | awk '{ gsub(/<[^>]*>/, "\n"); gsub(/\.\.\./, "\n"); gsub(/[0-9]+/, "\n"); print }' > "$work/frags"
  while IFS= read -r frag; do
    [ "${#frag}" -ge 8 ] || continue
    grep -qF -- "$frag" "$work/code" \
      || fail "troubleshooting.md quotes a message the code no longer prints: [$msg] (missing fragment: [$frag])"
    checked=$((checked + 1))
  done < "$work/frags"
done < "$work/msgs"

echo "PASS: troubleshooting_messages_test ($count messages, $checked fragments)"
