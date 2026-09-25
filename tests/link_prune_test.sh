#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# `install.sh link` prunes on-disk orphans - a link recorded in the
# PREVIOUS manifest that the current run no longer produces MUST be unlinked, but
# ONLY when it is still a symlink into $DOTFILES (the uninstall predicate).
# A real file or a symlink pointing outside the repo MUST survive.
#
# This drives the REAL entry point (`install.sh link` as a subprocess) TWICE
# against a cp -a copy of the repo used as $DOTFILES, so it proves BOTH halves at
# once: that link_manifest_finalize prunes with the right predicate AND that
# do_link actually wires $DOTFILES into it. A finalize that prunes correctly but a
# do_link that forgets to pass the root would pass a unit test of finalize alone
# and still ship the orphan - that is the pre-merge-engine defect's shape, and
# only the whole-path run catches it.
#
# Fully hermetic: cp -a repo copy + scratch HOME + pinned XDG_* + neutralized git
# config, mktemp + trap; never touches the real $HOME. Not on the shellcheck
# surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/link_prune_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# --- $DOTFILES = a copy of the repo we may mutate (remove a link source) ------
dots="$work/dotfiles"
cp -a "$repo_root" "$dots"
# Canonicalise to the PHYSICAL path (pwd -P), exactly as install.sh derives
# $DOTFILES. On macOS $TMPDIR is under /var → /private/var (a symlink), so a
# naive $work would never prefix-match the symlink targets install.sh writes;
# this also collapses the // that a trailing-slash $TMPDIR leaves.
dots="$(cd "$dots" && pwd -P)"
# Two synthetic, safe-to-remove configs so run 1 produces prunable links and run 2
# (with the sources gone) must reclaim BOTH - proving the loop handles >1/run, not
# just the first. Plain config/<prog>: OS-agnostic, no profile gate.
mkdir -p "$dots/config/prunetest"
printf 'x\n' > "$dots/config/prunetest/prunetest.conf"
mkdir -p "$dots/config/prunetest2"
printf 'y\n' > "$dots/config/prunetest2/prunetest2.conf"

# --- Scratch HOME + XDG, git neutralized (do_link touches no git, belt+braces) -
export HOME="$work/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" \
       XDG_STATE_HOME="$HOME/.local/state"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$HOME"
manifest="$XDG_STATE_HOME/dotfiles/manifest"
target="$XDG_CONFIG_HOME/prunetest"
target2="$XDG_CONFIG_HOME/prunetest2"

# --- Run 1: link everything, including the prunable configs -------------------
"$dots/install.sh" link >"$work/run1.log" 2>&1 \
  || fail "run 1: install.sh link exited non-zero: $(cat "$work/run1.log")"
[ -L "$target" ]  || fail "run 1: $target was not linked"
[ -L "$target2" ] || fail "run 1: $target2 was not linked"
case "$(readlink "$target")" in
  "$dots"/*) ;;
  *) fail "run 1: $target does not point into the repo copy" ;;
esac
grep -qxF "$target" "$manifest" || fail "run 1: manifest is missing $target"
# First-ever run has no prior manifest, so it must prune NOTHING. Match the
# specific prune line, not "prun" - the fixtures are NAMED prunetest and their
# linked lines contain that substring, which would false-positive a loose grep.
grep -qF "pruned orphan link" "$work/run1.log" \
  && fail "run 1: first-ever run (no prior manifest) must prune nothing" || :

# --- Negative controls: three stale manifest entries, two of which MUST survive.
# All are recorded in the (old) manifest but NOT produced by run 2, so all land in
# the prune candidate set. The predicate must spare (a) and (b), reclaim (c).
real_stale="$XDG_CONFIG_HOME/realfile_stale"      # (a) a REAL FILE, not a symlink
printf 'keep me\n' > "$real_stale"
foreign_stale="$XDG_CONFIG_HOME/foreign_stale"    # (b) a symlink OUTSIDE the repo
ln -s /tmp "$foreign_stale"
live_stale="$XDG_CONFIG_HOME/live_stale"          # (c) LIVE symlink INTO the repo
ln -s "$dots/install.sh" "$live_stale"            #     target still exists (not dangling)
printf '%s\n%s\n%s\n' "$real_stale" "$foreign_stale" "$live_stale" >> "$manifest"

# --- Remove the link SOURCES so run 2 no longer produces the prunetest links ---
rm -rf "$dots/config/prunetest" "$dots/config/prunetest2"

# --- Run 2: relink; orphans reclaimed, controls (a)/(b) left alone -------------
"$dots/install.sh" link >"$work/run2.log" 2>&1 \
  || fail "run 2: install.sh link exited non-zero: $(cat "$work/run2.log")"

# Both orphan symlinks are gone from disk AND from the manifest.
[ ! -L "$target" ] && [ ! -e "$target" ] \
  || fail "run 2: orphan link $target was NOT pruned (still on disk)"
[ ! -L "$target2" ] && [ ! -e "$target2" ] \
  || fail "run 2: second orphan $target2 was NOT pruned (loop stopped after one?)"
grep -qxF "$target" "$manifest" \
  && fail "run 2: pruned link $target is still recorded in the manifest" || :

# The prune announced each orphan BY NAME. A bare `grep -qi prun` is vacuous here:
# the foreign control emits a "prune: … leaving it" warn, and the fixture name
# "prunetest" contains "prun" - either satisfies a loose grep even on a SILENT
# prune. Match the exact per-target line instead.
grep -qF "pruned orphan link $target" "$work/run2.log" \
  || fail "run 2: the orphan prune produced no log line naming $target"
grep -qF "pruned orphan link $target2" "$work/run2.log" \
  || fail "run 2: the second orphan prune was not announced"

# NEGATIVE CONTROLS - the predicate is load-bearing:
[ -f "$real_stale" ] && [ ! -L "$real_stale" ] \
  || fail "run 2: a REAL FILE at a stale manifest path was wrongly removed"
[ -L "$foreign_stale" ] \
  || fail "run 2: a symlink pointing OUTSIDE the repo was wrongly removed"
# (c) a LIVE (non-dangling) symlink INTO the repo IS pruned - the shape a dropped
# exceptions-table arm leaves (source present, link rule gone), not just source-removal.
[ ! -L "$live_stale" ] && [ ! -e "$live_stale" ] \
  || fail "run 2: a LIVE (non-dangling) orphan symlink into the repo was not pruned"

# --- Partial run UNIONs, never strands -------------------------
# A rule-removal that COINCIDES with a partial run (rc=1) must keep the dropped
# entry in the manifest, or a replace would strand its orphan OFF the manifest -
# unreclaimable by any later clean run. Own scratch HOME so it can't disturb the
# main scenario. Four real `install.sh link` runs: link -> partial (union, no
# prune) -> clean (reclaim). Forces rc=1 with a real dir where alacritty links.
(
  export HOME="$work/home3" XDG_CONFIG_HOME="$work/home3/.config" \
         XDG_STATE_HOME="$work/home3/.local/state" XDG_CACHE_HOME="$work/home3/.cache"
  mkdir -p "$HOME"
  m="$XDG_STATE_HOME/dotfiles/manifest"
  mkdir -p "$dots/config/prunetest3"; printf 'z\n' > "$dots/config/prunetest3/prunetest3.conf"
  t3="$XDG_CONFIG_HOME/prunetest3"

  "$dots/install.sh" link >/dev/null 2>&1 || { echo "p3: clean link 1 failed"; exit 1; }
  [ -L "$t3" ]           || { echo "p3: prunetest3 was not linked"; exit 1; }
  grep -qxF "$t3" "$m"   || { echo "p3: manifest missing prunetest3 after run 1"; exit 1; }

  # Rule-removal AND a forced partial run (a real dir where alacritty links -> rc=1).
  rm -rf "$dots/config/prunetest3"
  conflict="$XDG_CONFIG_HOME/alacritty"; rm -rf "$conflict"; mkdir -p "$conflict/real"
  printf 'x\n' > "$conflict/real/keep"
  "$dots/install.sh" link >/dev/null 2>&1 && { echo "p3: partial run should have returned non-zero"; exit 1; }
  # Union kept the entry, and the rc-gate pruned nothing.
  grep -qxF "$t3" "$m" || { echo "p3: partial run DROPPED the rule-removed entry (would strand its orphan)"; exit 1; }
  [ -L "$t3" ]         || { echo "p3: partial run wrongly pruned the orphan"; exit 1; }
  [ -f "$conflict/real/keep" ] || { echo "p3: the conflict's real content was destroyed"; exit 1; }

  # Clear the conflict; a clean run now reclaims the entry the partial run preserved.
  rm -rf "$conflict"
  "$dots/install.sh" link >/dev/null 2>&1 || { echo "p3: clean link 2 failed"; exit 1; }
  { [ ! -L "$t3" ] && [ ! -e "$t3" ]; } || { echo "p3: clean run did NOT reclaim the preserved orphan"; exit 1; }
  grep -qxF "$t3" "$m" && { echo "p3: reclaimed entry still recorded in the manifest"; exit 1; } || :
  exit 0
) || fail "partial-run union / later-reclaim regressed"

echo "PASS: link_prune_test (orphans pruned incl. live+multiple; partial run unions + reclaims; real file + foreign symlink spared)"
