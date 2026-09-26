#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for bin/smoke's staging helpers - the disposable copy the smoke
# installs into so a run never touches the real checkout (dotfiles#18). The
# end-to-end smoke (tests/smoke_test.sh) runs against this repository, which CI
# checks out recursively, so it only ever takes the "initialized submodule"
# branch. These hermetic fixtures exercise the others:
#   - an initialized submodule is re-created from the real submodule's objects;
#   - an uninitialized one is filled from the common dir's modules gitdir (a main
#     clone next to a linked worktree), or from a sibling worktree's;
#   - with no local objects it is left uninitialized for install.sh to fetch
#     (nothing here fetches: stage_tree never does, and install.sh is not run);
#   - a staging failure returns nonzero, and through bin/smoke fails the run and
#     cleans up the partial copy.
# Every case also proves the source checkout is byte-identical afterwards.
#
# Bash 3.2 compatible so the macOS CI legs behave identically: no associative
# arrays, no mapfile, no ${var,,}.
set -euo pipefail

# A privilege skip: a root run cannot make a file unreadable to itself, which
# the partial-failure case needs, and install.sh refuses root anyway.
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  echo "SKIP: smoke_stage_test (running as root)"
  exit 0
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
smoke="$repo_root/bin/smoke"

# Sourcing bin/smoke defines the staging helpers and stops before its main body
# (its BASH_SOURCE guard). Everything above that guard runs in THIS shell: its
# `set -euo pipefail` applies here (the same options this test sets), and it
# scrubs the repository-local git environment, which this test wants too.
# `fail` is defined AFTER it, overriding the driver's.
# shellcheck source=bin/smoke
. "$smoke"
fail() { echo "FAIL: $*" >&2; exit 1; }
n=0
ok() { n=$((n + 1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/smoke_stage_test.XXXXXX")"
trap 'chmod -R u+rw "$work" 2>/dev/null; rm -rf "$work"' EXIT
# Fully hermetic identity/config; ignore any ambient global/system git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# Modern git blocks the file:// transport for submodules by default; allow it
# only on the fixture-building commands that need it (never globally).
allow='-c protocol.file.allow=always'

# umask pinned so a copy that lost its modes (extracted without -p, under the
# umask) is told apart from one that kept them: the fixtures set modes this
# umask strips.
umask 022

# Modes come from stat, GNU `-c` or BSD `-f`, never `ls -l` (a symlink's
# ` -> target` shifts its fields). The line naming the branch is printed on
# purpose: this file's own run is the proof, in a CI log, that a branch ran.
if stat -c '%a %n' . >/dev/null 2>&1; then
  stat_mode=(-c '%a %n'); echo "smoke_stage_test: stat branch GNU (-c '%a %n')"
else
  stat_mode=(-f '%Lp %N'); echo "smoke_stage_test: stat branch BSD (-f '%Lp %N')"
fi

# snap DIR - everything under DIR (paths, file bytes, modes and symlink
# targets), .smoke/ aside: that is bin/smoke's own gitignored scratch parent. A
# file named `unreadable` is listed but not read (the partial-failure fixture
# makes it so on purpose). Mirrors tests/smoke_test.sh's snap_submodules.
snap() {
  ( cd "$1" || exit 1
    find . -path ./.smoke -prune -o -print | LC_ALL=C sort
    find . -path ./.smoke -prune -o -type f ! -name unreadable -exec cksum {} + | LC_ALL=C sort
    find . -path ./.smoke -prune -o -exec stat "${stat_mode[@]}" {} + | LC_ALL=C sort
    find . -path ./.smoke -prune -o -type l -exec sh -c \
      'for l; do printf "%s -> " "$l"; readlink -n "$l"; printf "\n"; done' _ {} + | LC_ALL=C sort
  )
}
same() { # LABEL BEFORE AFTER
  [ "$2" = "$3" ] && return 0
  diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") >&2 || :
  fail "$1: stage_tree changed the source checkout"
}

# --- Fixtures -------------------------------------------------------------------
plugin="$work/plugin"
git init -q -b main "$plugin"
echo pinned-content > "$plugin/plugin.zsh"
git -C "$plugin" add plugin.zsh
git -C "$plugin" commit -qm init

super="$work/super"
git init -q -b main "$super"
echo tracked > "$super/a.txt"
git -C "$super" add a.txt
# shellcheck disable=SC2086
git -C "$super" $allow submodule add -q "$plugin" zsh/plugins/demo
git -C "$super" commit -qm "add demo plugin submodule"
pin="$(git -C "$super" rev-parse HEAD:zsh/plugins/demo)"

# mark_modes SRC - give the working tree modes the umask above would strip, and
# a symlink: a group/world-writable tracked file and untracked dir. git records
# neither (only the owner-execute bit), so only a mode-preserving copy keeps them.
mark_modes() {
  chmod 0666 "$1/a.txt"
  mkdir -p "$1/wide" && chmod 0777 "$1/wide"
  ln -sf a.txt "$1/link"
}
# assert_modes SRC DST LABEL - the copy kept the modes and the symlink target
# ("modes are smoked exactly as they sit in the real tree").
assert_modes() {
  local want got
  want="$(cd "$1" && stat "${stat_mode[@]}" a.txt wide && readlink link)"
  got="$(cd "$2" && stat "${stat_mode[@]}" a.txt wide && readlink link)"
  [ "$want" = "$got" ] || fail "$3: the copy did not keep the working tree's modes/symlink: want [$want] got [$got]"
}

# assert_populated DST - the copy's submodule is initialized (' ' prefix), at the
# pin, with its files, and its objects are borrowed from OBJ (an alternates path).
assert_populated() {
  local dst="$1" obj="$2" label="$3" st
  st="$(git -C "$dst" submodule status)"
  [ "${st:0:41}" = " $pin" ] \
    || fail "$label: copy's submodule not initialized at the pin: $st"
  [ "$(cat "$dst/zsh/plugins/demo/plugin.zsh")" = pinned-content ] \
    || fail "$label: copy's submodule files missing"
  [ "$(cat "$dst/zsh/plugins/demo/.git/objects/info/alternates")" = "$obj" ] \
    || fail "$label: copy's submodule does not borrow $obj"
  [ "$(cat "$dst/a.txt")" = tracked ] || fail "$label: copy lacks the superproject files"
  [ "$(git -C "$dst" rev-parse --show-toplevel)" = "$(cd "$dst" && pwd -P)" ] \
    || fail "$label: the copy is not a repository of its own"
}

# --- 1. Initialized submodule: re-created from the real submodule's objects ------
c1="$work/c1"
git clone -q "$super" "$c1"
# shellcheck disable=SC2086
git -C "$c1" $allow submodule update --init -q
echo uncommitted-edit > "$c1/a.txt"          # the copy smokes the working tree
mark_modes "$c1"
before="$(snap "$c1")"
stage_tree "$c1" "$work/d1" || fail "initialized: stage_tree failed"
same initialized "$before" "$(snap "$c1")"
st="$(git -C "$work/d1" submodule status)"
[ "${st:0:41}" = " $pin" ] || fail "initialized: copy's submodule not at the pin: $st"
[ "$(cat "$work/d1/zsh/plugins/demo/.git/objects/info/alternates")" \
  = "$(cd "$c1/.git/modules/zsh/plugins/demo/objects" && pwd -P)" ] \
  || fail "initialized: copy's submodule does not borrow the real submodule's objects"
[ "$(cat "$work/d1/a.txt")" = uncommitted-edit ] \
  || fail "initialized: the copy did not take the working tree's uncommitted edit"
assert_modes "$c1" "$work/d1" initialized
ok

# --- 2. Uninitialized, objects in the common dir (a main clone's) ----------------
git -C "$c1" worktree add -q --detach "$work/w1"
[ "$(git -C "$work/w1" submodule status | cut -c1)" = - ] || fail "fixture: w1 should be uninitialized"
mark_modes "$work/w1"
before_c1="$(snap "$c1")"; before_w1="$(snap "$work/w1")"
stage_tree "$work/w1" "$work/d2" || fail "common modules: stage_tree failed"
same "common modules (main clone)" "$before_c1" "$(snap "$c1")"
same "common modules (worktree)" "$before_w1" "$(snap "$work/w1")"
assert_populated "$work/d2" "$(cd "$c1/.git/modules/zsh/plugins/demo" && pwd -P)/objects" "common modules"
assert_modes "$work/w1" "$work/d2" "common modules"
ok

# --- 3. Uninitialized, objects only in a sibling worktree's modules gitdir -------
c2="$work/c2"
git clone -q "$super" "$c2"
git -C "$c2" worktree add -q --detach "$work/w2a"
# shellcheck disable=SC2086
git -C "$work/w2a" $allow submodule update --init -q
git -C "$c2" worktree add -q --detach "$work/w2b"
mark_modes "$work/w2b"
[ ! -e "$c2/.git/modules" ] || fail "fixture: the main clone c2 must hold no modules gitdir"
before_c2="$(snap "$c2")"; before_w2b="$(snap "$work/w2b")"
stage_tree "$work/w2b" "$work/d3" || fail "sibling worktree: stage_tree failed"
same "sibling worktree (main clone)" "$before_c2" "$(snap "$c2")"
same "sibling worktree (worktree)" "$before_w2b" "$(snap "$work/w2b")"
assert_populated "$work/d3" \
  "$(cd "$c2/.git/worktrees/w2a/modules/zsh/plugins/demo" && pwd -P)/objects" "sibling worktree"
assert_modes "$work/w2b" "$work/d3" "sibling worktree"
ok

# --- 4. Uninitialized, no local objects: left for install.sh, nothing fetched ----
c3="$work/c3"
git clone -q "$super" "$c3"
before="$(snap "$c3")"
stage_tree "$c3" "$work/d4" || fail "no local objects: stage_tree failed"
same "no local objects" "$before" "$(snap "$c3")"
[ "$(git -C "$work/d4" submodule status | cut -c1)" = - ] \
  || fail "no local objects: the copy's submodule must stay uninitialized (install.sh's to fetch)"
[ -z "$(ls -A "$work/d4/zsh/plugins/demo")" ] || fail "no local objects: the copy's submodule dir must stay empty"
[ ! -e "$work/d4/.git/modules" ] || fail "no local objects: stage_tree fetched something"
ok

# --- 5. Failure: nonzero, and the source untouched -------------------------------
# An unborn HEAD fails the first step (there is no commit to stage).
c4="$work/c4"
git init -q -b main "$c4"
echo x > "$c4/a.txt"
before="$(snap "$c4")"
if stage_tree "$c4" "$work/d5" 2>/dev/null; then fail "unborn HEAD: stage_tree must fail"; fi
same "unborn HEAD" "$before" "$(snap "$c4")"
ok

# --- 6. Partial failure through bin/smoke: the run fails and cleans up ------------
# A file the copy cannot read fails the tar step AFTER the copy's repository was
# created - a partial copy. The file is NON-empty on purpose: macOS bsdtar never
# opens a zero-length file for its data, so an empty unreadable file only drew
# an xattr-listing warning there (exit 0) and staged a complete copy, which made
# this case fail for the wrong reason on the macOS legs. bin/smoke must fail naming the staging step, leave no
# .smoke/run behind, and leave the source untouched. Needs zsh: bin/smoke skips
# before staging without it.
if command -v zsh >/dev/null 2>&1; then
  c5="$work/c5"
  git clone -q "$super" "$c5"
  mkdir -p "$c5/zsh" && : > "$c5/install.sh" && : > "$c5/zsh/zshrc"   # pass the ROOT guard
  echo secret > "$c5/unreadable" && chmod 000 "$c5/unreadable"
  before="$(snap "$c5")"
  if fout="$(env -u STRICT "$smoke" "$c5" 2>&1)"; then fail "partial failure: bin/smoke must fail: $fout"; fi
  grep -q 'could not stage' <<<"$fout" || fail "partial failure: failed for the WRONG reason: $fout"
  [ ! -e "$c5/.smoke/run" ] || fail "partial failure: bin/smoke left the partial copy behind"
  same "partial failure" "$before" "$(snap "$c5")"
  ok
else
  [ -z "${STRICT:-}" ] || fail "zsh not found and STRICT=1 - the partial-failure case cannot run"
  echo "SKIP: zsh unavailable - bin/smoke partial-failure cleanup not run"
fi

# --- 7. A tar that only WARNS must still fail the staging ------------------------
# macOS bsdtar reports some problems (an xattr it cannot list, for one) on
# stderr while exiting 0, so an exit-status check alone accepts a copy tar
# itself called incomplete. stage_tree treats any tar stderr as failure. A stub
# `tar` first on PATH proves it on any platform: it writes a warning, then runs
# the real tar and keeps its (successful) exit status.
real_tar="$(command -v tar)"
stub="$work/stub-bin"
mkdir -p "$stub"
printf '#!/bin/sh
echo "tar: stub: simulated warning" >&2
exec "%s" "$@"
' "$real_tar" > "$stub/tar"
chmod u+x "$stub/tar"
c6="$work/c6"
git clone -q "$super" "$c6"
before="$(snap "$c6")"
if (PATH="$stub:$PATH" stage_tree "$c6" "$work/d7") 2>/dev/null; then
  fail "tar warning: stage_tree must fail when tar writes to stderr, even on exit 0"
fi
same "tar warning" "$before" "$(snap "$c6")"
ok

echo "PASS: smoke_stage_test ($n cases)"
