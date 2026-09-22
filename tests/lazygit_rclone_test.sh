#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for config/lazygit/config.yml and the rclone/restic local-only
# templates: lazygit links by convention, rclone/restic are never linked, and no
# secret is committed. Two halves: a REPO-STRUCTURE audit (only README/*.example
# tracked under the secret-bearing dirs; the secret names are gitignored) and a
# real-repo LINK audit (run the actual link engine over the real repo into a
# scratch HOME and assert lazygit links while rclone does not). The link audit
# is the fast, zsh-free complement to the end-to-end assertion in bin/smoke.
# Fully hermetic: a mktemp scratch HOME, never the real $HOME. Not on the
# repo's shellcheck surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0

work="$(mktemp -d "${TMPDIR:-/tmp}/lazygit_rclone_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# --- nothing secret-shaped committable under the secret-bearing dirs.
# "What git would carry" = TRACKED files plus UNTRACKED-not-ignored ones (the
# latter so a new secret dropped in but not yet `git add`ed is still caught, and so
# this passes before the Task-17 files are first committed). An ignored secret
# (rclone.conf) is correctly excluded - that is the .gitignore guard working. Every
# such entry MUST be a README or a *.example; a real rclone.conf / restic password
# would show up here and fail the gate.
committable="$(
  git -C "$repo_root" ls-files config/rclone config/restic
  git -C "$repo_root" ls-files --others --exclude-standard config/rclone config/restic
)"
[ -n "$committable" ] || fail "config/rclone has no committable files (README/template missing?)"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base="${f##*/}"
  case "$base" in
    README.md|*.example) : ;;
    *) fail "secret-shaped file tracked under a local-only dir: $f" ;;
  esac
done <<EOF
$committable
EOF
pass=$((pass + 1))

# --- guard: the real secret names are gitignored so they can NEVER be
# committed by accident, while README/*.example stay tracked. `git check-ignore -q`
# exits 0 when the path IS ignored. A regressed .gitignore (dir excluded instead of
# its contents, or a missing re-include) is caught here.
git -C "$repo_root" check-ignore -q config/rclone/rclone.conf \
  || fail "config/rclone/rclone.conf is NOT gitignored - a real secret could be committed"
git -C "$repo_root" check-ignore -q config/restic/restic-password \
  || fail "config/restic/* is NOT gitignored - a real secret could be committed"
if git -C "$repo_root" check-ignore -q config/rclone/README.md; then
  fail "config/rclone/README.md IS gitignored - the README must stay tracked"
fi
if git -C "$repo_root" check-ignore -q config/rclone/rclone.conf.example; then
  fail "config/rclone/rclone.conf.example IS gitignored - the template must stay tracked"
fi
pass=$((pass + 4))

# --- lazygit config: present, non-empty, YAML-shaped (space indent, no tabs). We
# cannot assume a YAML parser in the stdlib, so validate structurally: a tab-
# indented line would silently break lazygit's YAML load, and the two top-level
# maps must be present.
cfg="$repo_root/config/lazygit/config.yml"
[ -s "$cfg" ] || fail "config/lazygit/config.yml is missing or empty"
if awk '/^\t/ { exit 1 }' "$cfg"; then : ; else fail "config.yml uses tab indentation (YAML requires spaces)"; fi
grep -q '^gui:' "$cfg" || fail "config.yml lost its top-level 'gui:' map"
grep -q '^git:' "$cfg" || fail "config.yml lost its top-level 'git:' map"
# Portability: the base config must not pin a Nerd Font (a terminal may lack one) -
# that belongs to a per-host tweak, not the tracked portable base.
grep -Eq 'nerdFontsVersion:[[:space:]]*"(2|3)"' "$cfg" \
  && fail "config.yml pins a Nerd Font version in the portable base (a terminal may lack it)"
pass=$((pass + 3))

# --- Real-repo LINK audit: run the actual engine over the real repo into a
# scratch HOME. lazygit (plain dir) MUST link; rclone (secret-bearing) MUST NOT.
# This is the scratch-HOME link audit, exercising the REAL config/ tree (the
# link_engine_test proves the same rule against a synthetic fixture).
log()  { :; }
warn() { :; }
# shellcheck source=/dev/null
. "$repo_root/lib/os.sh"
# shellcheck source=/dev/null
. "$repo_root/lib/link.sh"

export HOME="$work/home"
export XDG_CONFIG_HOME="$HOME/.config"
export LINK_MANIFEST="$work/manifest.tmp"
mkdir -p "$HOME"; : > "$LINK_MANIFEST"
link_tree "$repo_root" || true          # rc may be nonzero only on a real conflict

[ -L "$XDG_CONFIG_HOME/lazygit" ] \
  || fail "link engine did not link config/lazygit into ~/.config"
[ "$(readlink "$XDG_CONFIG_HOME/lazygit")" = "$repo_root/config/lazygit" ] \
  || fail "~/.config/lazygit points somewhere other than the repo's config/lazygit"
# Secrets must never link - check both -e and -L so a dangling link is caught too.
for secret in rclone restic; do
  { [ ! -e "$XDG_CONFIG_HOME/$secret" ] && [ ! -L "$XDG_CONFIG_HOME/$secret" ]; } \
    || fail "link engine linked config/$secret into ~/.config - secrets must never link"
done
# The manifest is the uninstall source of truth: lazygit recorded, secrets absent.
# `-F`: the paths hold regex metachars (mktemp '.', '.config'); match them literally.
grep -Fq "$XDG_CONFIG_HOME/lazygit" "$LINK_MANIFEST" \
  || fail "lazygit link not recorded in the manifest"
for secret in rclone restic; do
  if grep -Fq "$XDG_CONFIG_HOME/$secret" "$LINK_MANIFEST"; then
    fail "$secret wrongly recorded in the manifest (it must never be linked)"
  fi
done
pass=$((pass + 6))

echo "PASS: lazygit_rclone_test ($pass assertions)"
