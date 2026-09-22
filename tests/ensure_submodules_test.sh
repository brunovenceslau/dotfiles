#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# ensure_submodules - install.sh heals SHA-pinned plugin submodules
# that a NON-recursive `git clone` (one without --recurse-submodules)
# left empty; otherwise the static zsh loader silently
# degrades to no plugins. Two checks:
#   (1) the `install` dispatch actually wires the heal, and `link` stays pure
#       (link-only must not touch submodules);
#   (2) the detect-and-heal MECHANISM works on a real git fixture: a missing
#       submodule is detected via the '-' prefix of `git submodule status`,
#       `submodule update --init` populates it, and a healthy checkout is a no-op.
# Hermetic: every git object lives under a mktemp workspace and the submodule url
# is a local bare repo (file://) - no network. Bash 3.2 compatible (macOS legs):
# no associative arrays, no mapfile, no ${var,,}. Not part of the shellcheck surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
installer="$repo_root/install.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- (1) wiring: install heals, link does not --------------------------------
grep -q 'ensure_submodules()' "$installer" \
  || fail "install.sh no longer defines ensure_submodules"
# The call must sit in the `install` branch, not the `link` branch. Scan from
# `install)` to the next dispatch arm and require the call within it.
awk '/^  install\)/{f=1}
     f && /ensure_submodules/{found=1}
     /^  upgrade\)/{f=0}
     END{exit !found}' "$installer" \
  || fail "ensure_submodules is not wired into the install dispatch branch"
awk '/^  link\)/{f=1}
     f && /ensure_submodules/{bad=1}
     /^  install\)/{f=0}
     END{exit bad?1:0}' "$installer" \
  || fail "link-only must stay pure - ensure_submodules leaked into the link branch"

# --- (2) mechanism: detect-and-heal on a real fixture ------------------------
work="$(mktemp -d "${TMPDIR:-/tmp}/ensure_submodules_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# Fully hermetic identity/config; ignore any ambient global/system git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# Modern git blocks the file:// transport for submodules by default; allow it
# only via an explicit -c on the two commands that need it (never globally).
allow='-c protocol.file.allow=always'

# A bare "plugin" repo (default branch main) carrying one commit.
plugin="$work/plugin.git"
git init -q --bare -b main "$plugin"
wt="$work/plugin-wt"
git init -q -b main "$wt"
echo pinned-content > "$wt/plugin.zsh"
git -C "$wt" add plugin.zsh
git -C "$wt" commit -qm init
git -C "$wt" remote add origin "$plugin"
git -C "$wt" push -q origin main

# A superproject that vendors it as a submodule under zsh/plugins/ (our layout).
super="$work/super"
git init -q -b main "$super"
# shellcheck disable=SC2086
git -C "$super" $allow submodule add -q "$plugin" zsh/plugins/demo
git -C "$super" commit -qm "add demo plugin submodule"

# A NON-recursive clone - the failure mode: the submodule dir exists but is empty.
clone="$work/clone"
git clone -q "$super" "$clone"
git -C "$clone" submodule status | grep -q '^-' \
  || fail "an uninitialized submodule was not detected by the '-' prefix"
[ -z "$(ls -A "$clone/zsh/plugins/demo" 2>/dev/null)" ] \
  || fail "the submodule was unexpectedly populated by a plain clone"

# Heal it exactly as ensure_submodules does.
# shellcheck disable=SC2086
git -C "$clone" $allow submodule update --init >/dev/null 2>&1 \
  || fail "submodule update --init did not populate the missing submodule"
[ -f "$clone/zsh/plugins/demo/plugin.zsh" ] \
  || fail "the pinned submodule content is absent after the heal"

# A healthy checkout is a strict no-op: the detection guard must NOT fire.
if git -C "$clone" submodule status | grep -q '^-'; then
  fail "a healed checkout is still flagged as missing (guard would loop)"
fi

echo "ensure_submodules_test: OK (wiring + detect-and-heal + no-op on healthy)"
