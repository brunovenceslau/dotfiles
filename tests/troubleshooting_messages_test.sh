#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Doc-sync test: docs/troubleshooting.md is keyed to the exact text the
# framework prints, so a reworded message silently strands its section. Every
# message the page quotes must still exist in the code that prints it
# (install.sh, lib/*.sh and lib/*.py, zsh/). docs/signing-key.md quotes the
# identity step's and doctor's lines the same way, so it is held to the same
# rule.
#
# What counts as a quoted message:
#   * a line inside a fenced block that starts with `install: ` or `dotfiles: `
#     (install.sh prints the `install: ` prefix inline in its `printf`
#     calls, so it is dropped; a `doctor: <check>: ` head is checked as a CHECKS entry);
#   * a backtick span that starts with one of the framework's message prefixes
#     (`install: `, dropped like the fenced form, `upgrade: `, `link: `,
#     `packages: `, `uninstall: `, `one or more links`, `updates are
#     available`, `no successful update check`).
# Placeholders (`<path>`, `...`, a number such as the 30 in "30 days") stand for
# values the code interpolates, so each message is split at them and every
# literal fragment of 8 or more characters must appear verbatim in the code.
#
# Bash 3.2 compatible (the macOS CI legs run tests under /bin/bash).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
doc="$repo_root/docs/troubleshooting.md"
recipes="$repo_root/docs/signing-key.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$doc" ] || fail "docs/troubleshooting.md not found"
[ -f "$recipes" ] || fail "docs/signing-key.md not found"

work="$(mktemp -d "${TMPDIR:-/tmp}/troubleshooting_messages_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The code that prints the messages, flattened into one searchable file.
cat "$repo_root/install.sh" "$repo_root"/lib/*.sh "$repo_root"/lib/*.py "$repo_root"/zsh/zshrc "$repo_root"/zsh/*.zsh > "$work/code"

# 1. Fenced-block lines.
awk '/^```/ { inblock = !inblock; next }
     inblock && /^(install|dotfiles): / {
       sub(/^install: /, "")
       # doctor composes `doctor: <check>: <text>` from its CHECKS registry
       # (lib/host_identity.py): the check name must be a registry entry, and
       # the text is checked on its own.
       if (match($0, /^doctor: [^:<]+: /)) {
         name = substr($0, 9, RLENGTH - 10)
         print "(\"" name "\", Doctor."
         $0 = substr($0, RLENGTH + 1)
       }
       print
     }' "$doc" "$recipes" > "$work/msgs"
# 2. Backtick spans with a message prefix. Today exactly one `install: ` span
# exists (the root refusal in the symptom table) and it is also a prefix of a
# fenced line, so dropping `install: ` from this rule would leave the suite
# green; it is kept for the next span that stands alone.
grep -oE '`[^`]+`' "$doc" | sed 's/^`//; s/`$//' \
  | grep -E '^(install: |upgrade: |link: |packages: |uninstall: |one or more links|updates are available|no successful update check)' \
  | sed 's/^install: //' >> "$work/msgs" || true

# The page yields 191 messages today; 150 leaves room to trim the page while a
# broken extraction (a few messages left) still trips.
count="$(grep -c . "$work/msgs" || true)"
[ "$count" -ge 150 ] || fail "extracted only $count messages from the page (extraction rot?)"

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
