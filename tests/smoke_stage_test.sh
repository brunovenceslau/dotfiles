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
#     cleans up the partial copy;
#   - a tar that only warns on stderr still fails the staging;
#   - a working-tree entry named like a tar option (a leading -, or @ on
#     bsdtar) is copied as a file, never read as an option.
# Every case also proves the source checkout is byte-identical afterwards.
#
# Bash 3.2 compatible so the macOS CI legs behave identically: no associative
# arrays, no mapfile, no ${var,,}.
set -euo pipefail

# Root can read a mode-000 file, so the partial-failure case (6) cannot build
# its fixture as root; only that case is skipped, every other one runs.
is_root=0
[ "$(/usr/bin/id -u)" -ne 0 ] || is_root=1

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
c3="$work/c3"
git clone -q "$super" "$c3"
git -C "$c3" worktree add -q --detach "$work/w3a"
# shellcheck disable=SC2086
git -C "$work/w3a" $allow submodule update --init -q
git -C "$c3" worktree add -q --detach "$work/w3b"
mark_modes "$work/w3b"
[ ! -e "$c3/.git/modules" ] || fail "fixture: the main clone c3 must hold no modules gitdir"
before_c3="$(snap "$c3")"; before_w3b="$(snap "$work/w3b")"
stage_tree "$work/w3b" "$work/d3" || fail "sibling worktree: stage_tree failed"
same "sibling worktree (main clone)" "$before_c3" "$(snap "$c3")"
same "sibling worktree (worktree)" "$before_w3b" "$(snap "$work/w3b")"
assert_populated "$work/d3" \
  "$(cd "$c3/.git/worktrees/w3a/modules/zsh/plugins/demo" && pwd -P)/objects" "sibling worktree"
assert_modes "$work/w3b" "$work/d3" "sibling worktree"
ok

# --- 4. Uninitialized, no local objects: left for install.sh, nothing fetched ----
c4="$work/c4"
git clone -q "$super" "$c4"
before="$(snap "$c4")"
stage_tree "$c4" "$work/d4" || fail "no local objects: stage_tree failed"
same "no local objects" "$before" "$(snap "$c4")"
[ "$(git -C "$work/d4" submodule status | cut -c1)" = - ] \
  || fail "no local objects: the copy's submodule must stay uninitialized (install.sh's to fetch)"
[ -z "$(ls -A "$work/d4/zsh/plugins/demo")" ] || fail "no local objects: the copy's submodule dir must stay empty"
[ ! -e "$work/d4/.git/modules" ] || fail "no local objects: stage_tree fetched something"
ok

# --- 5. Failure: nonzero, and the source untouched -------------------------------
# An unborn HEAD fails the first step (there is no commit to stage).
c5="$work/c5"
git init -q -b main "$c5"
echo x > "$c5/a.txt"
before="$(snap "$c5")"
if stage_tree "$c5" "$work/d5" 2>/dev/null; then fail "unborn HEAD: stage_tree must fail"; fi
same "unborn HEAD" "$before" "$(snap "$c5")"
ok

# --- 6. Partial failure through bin/smoke: the run fails and cleans up ------------
# A file the copy cannot read fails the tar step AFTER the copy's repository was
# created - a partial copy. The file is NON-empty on purpose: macOS bsdtar never
# opens a zero-length file for its data, so an empty unreadable file only drew
# an xattr-listing warning there (exit 0) and staged a complete copy, which made
# this case fail for the wrong reason on the macOS legs. bin/smoke must fail
# naming the staging step, leave no .smoke/run behind, and leave the source
# untouched. Needs zsh: bin/smoke skips before staging without it.
if [ "$is_root" -eq 1 ]; then
  echo "SKIP: smoke_stage_test case 6 (running as root: a mode-000 file stays readable)"
elif command -v zsh >/dev/null 2>&1; then
  c6="$work/c6"
  git clone -q "$super" "$c6"
  mkdir -p "$c6/zsh" && : > "$c6/install.sh" && : > "$c6/zsh/zshrc"   # pass the ROOT guard
  echo secret > "$c6/unreadable" && chmod 000 "$c6/unreadable"
  before="$(snap "$c6")"
  if fout="$(env -u STRICT "$smoke" "$c6" 2>&1)"; then fail "partial failure: bin/smoke must fail: $fout"; fi
  grep -q 'could not stage' <<<"$fout" || fail "partial failure: failed for the WRONG reason: $fout"
  [ ! -e "$c6/.smoke/run" ] || fail "partial failure: bin/smoke left the partial copy behind"
  same "partial failure" "$before" "$(snap "$c6")"
  ok
else
  [ -z "${STRICT:-}" ] || fail "zsh not found and STRICT=1 - the partial-failure case cannot run"
  echo "SKIP: zsh unavailable - bin/smoke partial-failure cleanup not run"
fi

# --- 7. A tar that only WARNS must still fail the staging ------------------------
# macOS bsdtar reports some problems (an xattr it cannot list, for one) on
# stderr while exiting 0, so an exit-status check alone accepts a copy tar
# itself called incomplete. stage_tree treats any tar stderr as failure. A stub
# `tar` first on PATH proves it on any platform. It warns ONLY after the real
# tar succeeded, and exits 0: a real tar failure prints a different line and
# keeps its status, so this case cannot pass on some other tar failure.
real_tar="$(command -v tar)"
stub="$work/stub-bin"
mkdir -p "$stub"
printf '#!/bin/sh
"%s" "$@" || { rc=$?; echo "tar-stub: the REAL tar failed" >&2; exit "$rc"; }
echo "tar: stub: simulated warning" >&2
exit 0
' "$real_tar" > "$stub/tar"
chmod u+x "$stub/tar"
c7="$work/c7"
git clone -q "$super" "$c7"
before="$(snap "$c7")"
if werr="$( (PATH="$stub:$PATH" stage_tree "$c7" "$work/d7") 2>&1)"; then
  fail "tar warning: stage_tree must fail when tar writes to stderr, even on exit 0"
fi
# The status alone would pass for ANY failure. The replayed stub warning under
# stage_tree's own verdict, no real tar failure, and a complete extract prove
# it failed on the stderr rule alone.
grep -q 'tar did not copy' <<<"$werr" \
  || fail "tar warning: failed for the WRONG reason (no 'did not copy'): $werr"
grep -q 'tar: stub: simulated warning' <<<"$werr" \
  || fail "tar warning: the stub's warning was not replayed: $werr"
if grep -q 'the REAL tar failed' <<<"$werr"; then
  fail "tar warning: the real tar failed, so this is not the warning-only path: $werr"
fi
[ "$(cat "$work/d7/a.txt" 2>/dev/null)" = tracked ] \
  || fail "tar warning: the copy is incomplete, so tar did not merely warn: $werr"
same "tar warning" "$before" "$(snap "$c7")"
ok

# --- 8. An entry named like a tar option is a file, never an option -------------
# The names reach tar as arguments. Bare, `--exclude=a.txt` and `-v` are parsed
# as options (the entry is never copied, a.txt is silently dropped), the two
# --checkpoint names make GNU tar run a command, and bsdtar reads `@x.tar` as
# "add the entries of this archive". On GNU tar the `@` name is an ordinary
# file either way, so its half is proven only on the macOS legs.
c8="$work/c8"
git clone -q "$super" "$c8"
echo dash-entry > "$c8/--exclude=a.txt"
echo dash-short > "$c8/-v"
echo at > "$c8/@x.tar"
echo ckpt > "$c8/--checkpoint=1"
echo ckpt-action > "$c8/--checkpoint-action=exec=touch PWNED"
before="$(snap "$c8")"
stage_tree "$c8" "$work/d8" || fail "option-like names: stage_tree failed"
same "option-like names" "$before" "$(snap "$c8")"
[ "$(cat "$work/d8/--exclude=a.txt")" = dash-entry ] \
  || fail "option-like names: the entry named --exclude=a.txt was not copied"
[ "$(cat "$work/d8/-v")" = dash-short ] || fail "option-like names: the entry named -v was not copied"
[ "$(cat "$work/d8/@x.tar")" = at ] || fail "option-like names: the entry named @x.tar was not copied as a file"
[ "$(cat "$work/d8/--checkpoint=1")" = ckpt ] \
  || fail "option-like names: the entry named --checkpoint=1 was not copied"
[ "$(cat "$work/d8/--checkpoint-action=exec=touch PWNED")" = ckpt-action ] \
  || fail "option-like names: the --checkpoint-action entry was not copied"
[ "$(cat "$work/d8/a.txt")" = tracked ] \
  || fail "option-like names: a.txt missing, the --exclude= name was read as a tar option"
for d in "$c8" "$work/d8" "$PWD"; do
  [ ! -e "$d/PWNED" ] || fail "option-like names: tar ran the --checkpoint-action command (PWNED in $d)"
done
ok

echo "PASS: smoke_stage_test ($n cases)"
