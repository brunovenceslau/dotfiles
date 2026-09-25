#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# The write-back closure. The governing rule this proves:
# a TRACKED file MUST NOT be the path a tool treats as its own WRITABLE config.
# The live site is exercised through the REAL link entry point (link_tree, which
# install.sh's do_link calls) against a mktemp fixture - never the real repo:
# ~/.config/git/config - `git config --global` writes here; it MUST be a real,
# machine-local file that [include]s the tracked config/git/config, so global
# writes land locally while tracked content is still honored.
#
# Every assertion is RED-proven: run against the pre-fix code (config/git symlinked
# whole) each write reaches the tracked file and the assertion fails; after the fix
# it passes.
#
# Hermetic: mktemp scratch HOME + pinned XDG_*; GIT_CONFIG_SYSTEM=/dev/null and no
# GIT_CONFIG_GLOBAL pin (so `git config --global` resolves to the XDG path under our
# scratch HOME); git runs from a NEUTRAL non-repo cwd so no repo-local scope leaks.
# A non-hermetic test here once destroyed the maintainer's signing identity, so the
# fixture is a COPY of config/git - the real repo is NEVER written. Not part of
# the shellcheck surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0

if ! command -v git >/dev/null 2>&1; then
  if [ -n "${STRICT:-}" ]; then fail "git unavailable and STRICT=1"; fi
  echo "SKIP: git unavailable"; exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/writeback_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM

log()  { :; }
warn() { :; }
# shellcheck source=/dev/null
. "$repo_root/lib/os.sh"
# shellcheck source=/dev/null
. "$repo_root/lib/link.sh"
# shellcheck source=/dev/null
. "$repo_root/lib/uninstall.sh"

# --- Hermetic environment -----------------------------------------------------
export HOME="$work/home"; mkdir -p "$HOME"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export GIT_CONFIG_SYSTEM=/dev/null       # ignore the host's /etc/gitconfig
unset GIT_CONFIG_GLOBAL 2>/dev/null || true   # let `--global` resolve to the XDG file
mkdir -p "$XDG_STATE_HOME/dotfiles" "$work/neutral"
DOTFILES="$work/dotfiles"; export DOTFILES     # some helpers read $DOTFILES

# git on a NEUTRAL cwd so the real dotfiles repo's local scope can never leak in.
gcfg() { git -C "$work/neutral" "$@"; }

# --- Fixture: a COPY of the tracked surfaces (never the real repo) -------------
root="$DOTFILES"
mkdir -p "$root/config/git"
cp "$repo_root/config/git/config" "$root/config/git/config"
cp "$root/config/git/config" "$work/git-config.pristine"   # byte baseline

manifest="$work/manifest"
reset_home() { rm -rf "$XDG_CONFIG_HOME/git"; }

# =============================================================================
# (a) GIT - `git config --global` must NOT reach the tracked config/git/config
# =============================================================================
reset_home
LINK_MANIFEST="$manifest"; : > "$manifest"
link_tree "$root" || fail "(a) link_tree returned non-zero"

[ ! -L "$XDG_CONFIG_HOME/git" ] \
  || fail "(a) ~/.config/git is a symlink into the repo - global writes reach the tracked file"
[ -f "$XDG_CONFIG_HOME/git/config" ] && [ ! -L "$XDG_CONFIG_HOME/git/config" ] \
  || fail "(a) ~/.config/git/config is not a real local file"
# tracked content is still honored through the include chain
[ "$(gcfg config --get fetch.fsckObjects)" = true ] \
  || fail "(a) tracked config not honored through the local [include] (fetch.fsckObjects)"
pass=$((pass + 3))

# Plant the exact production hazards AFTER install: an identity and safe.directory=*
gcfg config --global user.name 'WB Test' || fail "(a) could not write user.name --global"
gcfg config --global --add safe.directory '*' || fail "(a) could not write safe.directory --global"

cmp -s "$work/git-config.pristine" "$root/config/git/config" \
  || fail "(a) a --global write reached the TRACKED config/git/config (byte-changed)"
# and the writes landed in the LOCAL file, which is what --show-origin must name
origin="$(gcfg config --show-origin --get user.name)"
case "$origin" in
  *"$XDG_CONFIG_HOME/git/config"*) ;;
  *) fail "(a) user.name origin is not the local ~/.config/git/config: $origin" ;;
esac
grep -q 'WB Test' "$XDG_CONFIG_HOME/git/config" \
  || fail "(a) the --global write did not land in the local ~/.config/git/config"
# Match the KEY, not the bare word "safe": git writes it as a `[safe]` section
# with a `directory =` line, and a bare grep also hits ordinary prose in the
# file's comments (it did, once this config grew a sentence containing "safe").
if grep -qiE '^[[:space:]]*\[safe\]|^[[:space:]]*directory[[:space:]]*=' "$root/config/git/config"; then
  fail "(a) safe.directory reached the tracked file"
fi
pass=$((pass + 3))

# =============================================================================
# (f) UNINSTALL - the machine-local file is NOT a managed link, so a
#     manifest-driven uninstall must never remove it
# =============================================================================
reset_home
: > "$manifest"
link_tree "$root" || fail "(f) link_tree returned non-zero"
# the machine-local path may not be recorded as a managed link
grep -q "$XDG_CONFIG_HOME/git/config" "$manifest" \
  && fail "(f) ~/.config/git/config was recorded in the uninstall manifest"
# run the real manifest-driven uninstall and confirm they survive
uninstall_links "$manifest" || fail "(f) uninstall_links returned non-zero"
[ -f "$XDG_CONFIG_HOME/git/config" ] && [ ! -L "$XDG_CONFIG_HOME/git/config" ] \
  || fail "(f) uninstall removed the machine-local ~/.config/git/config"
pass=$((pass + 2))

echo "PASS: writeback_test ($pass assertions)"
