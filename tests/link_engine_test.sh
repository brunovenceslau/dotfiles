#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for the convention-based link engine in lib/link.sh - link_tree()
# and the manifest. Covers config/<prog> -> ~/.config/<prog>; that NO @suffix is
# recognized, including the @darwin that once gated on macOS; home/<file> ->
# ~/.<file>; bin/* -> ~/.local/bin/*; gnupg (only gpg.conf/gpg-agent.conf, never
# the dir); rclone/restic never linked; and the manifest holding exactly the
# created links, byte-stable across re-runs. Fully hermetic: a mktemp fixture
# ROOT and a mktemp scratch HOME, like tests/link_test.sh; never touches the
# real $HOME. The @darwin fixture is kept deliberately: macOS is the only
# target, so the gate was removed, and the fixture now PROVES the suffix carries
# no meaning rather than leaving its absence untested. Not on the repo's
# lint (shellcheck) surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/link_engine_test.XXXXXX")"
warnlog="$work/warn.log"
: > "$warnlog"
trap 'rm -rf "$work"' EXIT

# link_tree()/link() report via log/warn provided by the caller (install.sh);
# stub them so the library is exercised in isolation and warnings can be checked.
log()  { :; }
warn() { printf '%s\n' "$*" >> "$warnlog"; }

# shellcheck source=/dev/null
. "$repo_root/lib/link.sh"

# --- Fixture ROOT: one entry per convention + every exception ----------------
root="$work/dotfiles"
mkdir -p "$root"/config/alacritty
printf 'x\n'            > "$root/config/alacritty/alacritty.toml"
mkdir -p "$root"/config/tmux                             # plain dir -> always links
printf 'x\n'            > "$root/config/tmux/tmux.conf"
mkdir -p "$root"/config/karabiner@darwin                 # ex-OS gate -> now just an unknown suffix
printf 'x\n'            > "$root/config/karabiner@darwin/karabiner.json"
mkdir -p "$root"/config/weird@bsd                         # unknown suffix -> skip
printf 'x\n'            > "$root/config/weird@bsd/x.conf"
mkdir -p "$root"/config/gnupg/private-keys-v1.d           # only the 2 files link
printf 'x\n'            > "$root/config/gnupg/gpg.conf"
printf 'x\n'            > "$root/config/gnupg/gpg-agent.conf"
printf 'secret\n'      > "$root/config/gnupg/private-keys-v1.d/key"
mkdir -p "$root"/config/rclone                            # secrets -> never
printf 'x\n'            > "$root/config/rclone/rclone.conf.example"
mkdir -p "$root"/config/restic                            # secrets -> never
printf 'x\n'            > "$root/config/restic/restic.env.example"
printf 'x\n'            > "$root/config/README.md"         # plain file -> ignored
mkdir -p "$root"/home "$root"/bin
printf 'x\n'            > "$root/home/gitconfig"
printf 'x\n'            > "$root/home/hushlogin"
printf '#!/bin/sh\n'   > "$root/bin/dotfiles-hello"


# Scratch HOME + XDG target, all under the throwaway work dir.
export HOME="$work/home"
export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$HOME"

manifest_tmp="$work/manifest.tmp"      # raw per-run collection ($LINK_MANIFEST)
manifest_out="$work/manifest"          # finalized (sorted, deduped) manifest
export LINK_MANIFEST="$manifest_tmp"

run_engine() {                          # a fresh install.sh-style relink pass
  : > "$LINK_MANIFEST"
  link_tree "$root"
  link_manifest_finalize "$manifest_out"
}

# --- Run 1 -------------------------------------------------------------------
run_engine

is_link_to() {                          # is_link_to LINK EXPECTED_TARGET
  [ -L "$1" ] || return 1
  [ "$(readlink "$1")" = "$2" ]
}

# Plain config/<prog> -> ~/.config/<prog>.
is_link_to "$HOME/.config/alacritty" "$root/config/alacritty" \
  || fail "config/alacritty not linked to ~/.config/alacritty"

# EVERY @suffix is unknown now, @darwin included: skipped, warned about, and
# never stripped into a bare target name.
[ -e "$HOME/.config/karabiner" ] && fail "@darwin dir linked - the OS gate came back"
[ -e "$HOME/.config/karabiner@darwin" ] && fail "the @suffix leaked into the target name"
grep -q 'karabiner@darwin' "$warnlog" || fail "@darwin did not warn as an unknown suffix"
[ -e "$HOME/.config/weird" ] && fail "unknown @suffix wrongly linked"
grep -q 'weird@bsd' "$warnlog" || fail "unknown @suffix did not warn"

# Gnupg links only the two files into ~/.gnupg; never the dir/keys.
{ [ -d "$HOME/.gnupg" ] && [ ! -L "$HOME/.gnupg" ]; } \
  || fail "~/.gnupg must be a real dir, never a symlink to the repo"
is_link_to "$HOME/.gnupg/gpg.conf" "$root/config/gnupg/gpg.conf" \
  || fail "gnupg gpg.conf not linked"
is_link_to "$HOME/.gnupg/gpg-agent.conf" "$root/config/gnupg/gpg-agent.conf" \
  || fail "gnupg gpg-agent.conf not linked"
[ -e "$HOME/.gnupg/private-keys-v1.d" ] && fail "gnupg secret keyring dir was linked"
[ -L "$HOME/.config/gnupg" ] && fail "gnupg dir wrongly linked under ~/.config"
# Secret hygiene: a framework-created ~/.gnupg must be 0700 (ls perms string is
# portable across GNU/BSD, unlike stat's format).
gnupg_perm="$(ls -ld "$HOME/.gnupg" | cut -c1-10)"
[ "$gnupg_perm" = "drwx------" ] || fail "~/.gnupg not created 0700 (got: $gnupg_perm)"

# rclone/restic (secret-bearing) are never linked.
[ -e "$HOME/.config/rclone" ] && fail "rclone wrongly linked (secrets)"
[ -e "$HOME/.config/restic" ] && fail "restic wrongly linked (secrets)"

# Only program *directories* under config/ are linked; a plain file
# directly under config/ (README, .DS_Store) must be ignored, not linked.
[ -e "$HOME/.config/README.md" ] && fail "plain file under config/ was linked"

# home/<file> -> ~/.<file>.
is_link_to "$HOME/.gitconfig" "$root/home/gitconfig" || fail "home/gitconfig not linked"
is_link_to "$HOME/.hushlogin" "$root/home/hushlogin" || fail "home/hushlogin not linked"

# bin/* -> ~/.local/bin/*.
is_link_to "$HOME/.local/bin/dotfiles-hello" "$root/bin/dotfiles-hello" \
  || fail "bin/dotfiles-hello not linked to ~/.local/bin"

# The manifest lists EXACTLY the created links (sorted, deduped).
expected="$work/expected"
{
  printf '%s\n' "$HOME/.config/alacritty"
  printf '%s\n' "$HOME/.config/tmux"
  printf '%s\n' "$HOME/.gitconfig"
  printf '%s\n' "$HOME/.gnupg/gpg-agent.conf"
  printf '%s\n' "$HOME/.gnupg/gpg.conf"
  printf '%s\n' "$HOME/.hushlogin"
  printf '%s\n' "$HOME/.local/bin/dotfiles-hello"
} | sort -u > "$expected"
diff -u "$expected" "$manifest_out" \
  || fail "manifest is not exactly the set of created links"

# --- Run 2: idempotent + byte-stable manifest ---
cp "$manifest_out" "$work/manifest.run1"
run_engine
diff -u "$work/manifest.run1" "$manifest_out" \
  || fail "manifest changed on a re-run (must be byte-stable)"
if find "$HOME" -name '*.bak' | grep -q .; then   # no -quit: BSD find lacks it
  fail "a re-run created a spurious .bak somewhere under HOME"
fi
is_link_to "$HOME/.config/tmux" "$root/config/tmux" \
  || fail "re-run disturbed an existing link"

# --- Conflict mid-walk: continue-and-report, never abort -------
# A real directory at one target makes link() refuse (warn + return 1). link_tree
# must place every OTHER link, leave the conflict intact, and RETURN NON-ZERO so
# the installer can fail loudly after doing all the safe work - it must neither
# abort mid-walk (dropping the remaining links) nor silently succeed. The manifest
# must record the placed links and NOT the refused one.
(
  export HOME="$work/home_conflict" XDG_CONFIG_HOME="$work/home_conflict/.config"
  export LINK_MANIFEST="$work/manifest.conflict"
  mkdir -p "$XDG_CONFIG_HOME/alacritty/real"          # real dir where alacritty links
  printf 'keep\n' > "$XDG_CONFIG_HOME/alacritty/real/f"
  : > "$LINK_MANIFEST"
  rc=0; link_tree "$root" || rc=$?
  if [ "$rc" -eq 0 ]; then echo "conflict: link_tree must return non-zero when a link is refused"; exit 1; fi
  if [ ! -f "$XDG_CONFIG_HOME/alacritty/real/f" ]; then echo "conflict: pre-existing dir content lost"; exit 1; fi
  if [ -L "$XDG_CONFIG_HOME/alacritty" ]; then echo "conflict: real dir replaced by a symlink"; exit 1; fi
  if [ ! -L "$XDG_CONFIG_HOME/tmux" ]; then echo "conflict: walk stopped early - a later link was not placed"; exit 1; fi
  link_manifest_finalize "$work/manifest.conflict.out"
  if grep -q 'alacritty' "$work/manifest.conflict.out"; then echo "conflict: refused link wrongly recorded"; exit 1; fi
  if ! grep -q "config/tmux" "$work/manifest.conflict.out"; then echo "conflict: placed link not recorded"; exit 1; fi
  exit 0
) || fail "link_tree continue-and-report on conflict regressed"

# --- Empty-but-present config/: no links, no error, empty manifest -----------
(
  export HOME="$work/home_empty" XDG_CONFIG_HOME="$work/home_empty/.config"
  export LINK_MANIFEST="$work/manifest.empty"
  mkdir -p "$HOME"; : > "$LINK_MANIFEST"
  empty_root="$work/empty_root"; mkdir -p "$empty_root/config"    # present but empty
  link_tree "$empty_root" || { echo "empty: link_tree errored on an empty tree"; exit 1; }
  link_manifest_finalize "$work/manifest.empty.out"
  if [ -s "$work/manifest.empty.out" ]; then echo "empty: empty tree produced manifest entries"; exit 1; fi
  exit 0
) || fail "empty-tree / glob-nomatch handling regressed"

# --- link_manifest_merge unions without dropping prior entries (abort path) ---
# Completeness: on an aborted run install.sh unions the links made
# so far into the existing manifest. Prove the union directly (no install needed).
(
  export LINK_MANIFEST="$work/merge_scratch"
  base="$work/merge_manifest"
  printf '%s\n' "/old/A" "/old/B" | LC_ALL=C sort -u > "$base"
  printf '%s\n' "/new/C" "/old/B" > "$LINK_MANIFEST"        # C is new, B overlaps
  link_manifest_merge "$base"
  printf '%s\n' "/old/A" "/old/B" "/new/C" | LC_ALL=C sort -u > "$work/merge_expected"
  diff -u "$work/merge_expected" "$base" || { echo "merge: union into existing manifest wrong"; exit 1; }
  # And with no prior manifest (first-install abort): scratch becomes the manifest.
  fresh="$work/merge_fresh"; rm -f "$fresh"
  printf '%s\n' "/new/D" "/new/E" > "$LINK_MANIFEST"
  link_manifest_merge "$fresh"
  printf '%s\n' "/new/D" "/new/E" | LC_ALL=C sort -u > "$work/merge_fresh_exp"
  diff -u "$work/merge_fresh_exp" "$fresh" || { echo "merge: union with no prior manifest wrong"; exit 1; }
  # The abort-path union must NEVER prune. A live link the base
  # manifest records but the partial scratch omits must survive on disk - merge is
  # a superset, not a finalize. Guards against anyone adding an rm to this path.
  live="$work/live_target"; ln -s "$root" "$live"          # a symlink INTO the repo
  printf '%s\n' "$live" | LC_ALL=C sort -u > "$work/merge_live_base"
  printf '%s\n' "/new/F" > "$LINK_MANIFEST"                 # a partial run made 1 new link
  link_manifest_merge "$work/merge_live_base"
  [ -L "$live" ] || { echo "merge: pruned a still-live link on the abort path"; exit 1; }
  grep -qxF "$live" "$work/merge_live_base" || { echo "merge: dropped a live link"; exit 1; }
  exit 0
) || fail "link_manifest_merge union (abort-path completeness) regressed"

# --- Empty ROOT disables the prune -----------------------------
# finalize WITHOUT a repo root must publish the manifest but NEVER unlink - even an
# orphan symlink pointing INTO the repo. Guards the `[ -n "$root" ]` gate: drop it
# and "$root"/* becomes /*, which would match (and delete) every absolute orphan.
(
  export LINK_MANIFEST="$work/noroot_scratch"
  dest="$work/noroot_manifest"
  orphan="$work/noroot_orphan"; ln -s "$root/config/alacritty" "$orphan"   # into repo
  printf '%s\n' "$orphan" | LC_ALL=C sort -u > "$dest"      # prior manifest recorded it
  : > "$LINK_MANIFEST"                                       # this run produces nothing
  link_manifest_finalize "$dest"                            # NO root arg -> prune off
  [ -L "$orphan" ] || { echo "noroot: root-less finalize wrongly pruned an orphan"; exit 1; }
  exit 0
) || fail "empty-ROOT finalize no-op regressed"

echo "PASS: link_engine_test"
