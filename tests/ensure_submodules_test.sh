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
grep -q '^-' <<<"$(git -C "$clone" submodule status)" \
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
if grep -q '^-' <<<"$(git -C "$clone" submodule status)"; then
  fail "a healed checkout is still flagged as missing (guard would loop)"
fi

# --- (3) the heal refuses a corrupt plugin object, whatever the config says ---
# ensure_submodules forces fetch/transfer.fsckObjects with -c, because the
# tracked config that sets them is not reached through a pre-existing real
# ~/.config/git/config. Here the ONLY global config turns fsck OFF (and allows
# the file:// transport the fixture needs); the pinned plugin commit carries a
# tree with a duplicate entry. The real ensure_submodules, sourced from
# install.sh, must fail to populate the submodule.
bad="$work/badplugin.git"; git init -q --bare -b main "$bad"
bwt="$work/badplugin-wt"; git init -q -b main "$bwt"
blob="$(printf x | git -C "$bwt" hash-object -w --stdin)"
raw="$(printf '%s' "$blob" | sed 's/../\\x&/g')"
# shellcheck disable=SC2059  # the format IS the payload: \xHH escapes of the blob id
{ printf '100644 a\0'; printf "$raw"; printf '100644 a\0'; printf "$raw"; } > "$work/duptree"
t="$(git -C "$bwt" hash-object -t tree --literally -w "$work/duptree")"
c="$(git -C "$bwt" commit-tree "$t" -m malformed)"
git -C "$bwt" update-ref refs/heads/main "$c"
git -C "$bwt" push -q "$bad" main
bsuper="$work/badsuper"; git init -q -b main "$bsuper"
git -C "$bsuper" $allow submodule add -q "file://$bad" zsh/plugins/bad >/dev/null 2>&1 \
  || fail "fixture: could not vendor the malformed plugin (fsck on during setup?)"
git -C "$bsuper" commit -qm "add malformed plugin"
bclone="$work/badclone"; git clone -q "$bsuper" "$bclone"
printf '[protocol "file"]\n\tallow = always\n[fetch]\n\tfsckObjects = false\n[transfer]\n\tfsckObjects = false\n' > "$work/nofsck.gitconfig"
out="$(
  GIT_CONFIG_GLOBAL="$work/nofsck.gitconfig" GIT_CONFIG_NOSYSTEM=1 bash -c '
    . "$1"                       # functions only: the dispatch is guarded
    DOTFILES="$2"; ensure_submodules' _ "$installer" "$bclone" 2>&1
)" || true
[ ! -e "$bclone/zsh/plugins/bad/a" ] \
  || fail "ensure_submodules populated a submodule whose pinned commit is malformed (fsck not forced)"
grep -q 'submodule init failed' <<<"$out" \
  || fail "a refused corrupt submodule did not warn: $out"

echo "ensure_submodules_test: OK (wiring + detect-and-heal + no-op on healthy + corrupt object refused)"
