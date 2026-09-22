#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for lib/link.sh - the link() primitive. Covers the backup contract
# (regular file -> .bak; symlink incl. dangling replaced without backup; regular
# directory refused loudly) and the idempotent re-run: no new .bak, identical
# link. Uses an isolated mktemp workspace like the other tooling tests; never
# touches the real $HOME. Not part of the shellcheck surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
linklib="$repo_root/lib/link.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/link_test.XXXXXX")"
warnlog="$work/warn.log"
: > "$warnlog"
trap 'rm -rf "$work"' EXIT

# link() reports via log/warn provided by its caller (install.sh); stub them so
# the library is exercised in isolation and warn output can be asserted.
log()  { :; }
warn() { printf '%s\n' "$*" >> "$warnlog"; }

# shellcheck source=/dev/null
. "$linklib"

src="$work/src"; printf 'payload\n' > "$src"

# --- 1. Fresh target: creates the symlink and any missing parent dirs --------
dest="$work/nested/dir/dest"
link "$src" "$dest" || fail "link into fresh nested path returned non-zero"
[ -L "$dest" ] || fail "dest is not a symlink"
[ "$(readlink "$dest")" = "$src" ] || fail "dest points to the wrong target"

# --- 2. Pre-existing regular file: backed up to .bak, then replaced ----------
dest="$work/regular"
printf 'user data\n' > "$dest"
link "$src" "$dest" || fail "link over regular file returned non-zero"
[ -L "$dest" ] || fail "regular file not replaced by a symlink"
[ -f "$dest.bak" ] || fail "regular file not backed up to .bak"
[ "$(cat "$dest.bak")" = "user data" ] || fail ".bak lost the original content"

# --- 3. Idempotent re-run: no new .bak, link unchanged --------
dest="$work/idempotent"
ln -s "$src" "$dest"                    # establish the intended link independently
link "$src" "$dest" || fail "idempotent re-link returned non-zero"
if [ -e "$dest.bak" ]; then fail "re-run created a spurious .bak on a live link"; fi
[ "$(readlink "$dest")" = "$src" ] || fail "re-run changed the link target"

# --- 4. Existing wrong symlink: repointed without a backup -------------------
dest="$work/wrong_symlink"
ln -s "$work/other" "$dest"
link "$src" "$dest" || fail "relink over a wrong symlink returned non-zero"
[ "$(readlink "$dest")" = "$src" ] || fail "wrong symlink not repointed"
if [ -e "$dest.bak" ]; then fail "symlink replacement wrongly created a .bak"; fi

# --- 5. Dangling symlink: replaced without a backup -----------
dest="$work/dangling"
ln -s "$work/nonexistent" "$dest"
{ [ -L "$dest" ] && [ ! -e "$dest" ]; } || fail "test setup: dest is not dangling"
link "$src" "$dest" || fail "relink over a dangling symlink returned non-zero"
[ "$(readlink "$dest")" = "$src" ] || fail "dangling symlink not replaced"
if [ -e "$dest.bak" ]; then fail "dangling symlink replacement created a .bak"; fi

# --- 6. Regular directory: refused loudly, left intact --------
dest="$work/adir"
mkdir "$dest"; printf 'keep\n' > "$dest/inside"
: > "$warnlog"
if link "$src" "$dest"; then fail "link over a regular directory should fail"; fi
{ [ -d "$dest" ] && [ ! -L "$dest" ]; } || fail "directory was not left intact"
[ -f "$dest/inside" ] || fail "directory contents were touched"
grep -q 'refusing to replace' "$warnlog" || fail "directory refusal used the wrong warning"

# --- 7. Missing source: refused, nothing created ----------------------------
dest="$work/from_missing"
: > "$warnlog"
if link "$work/does_not_exist" "$dest"; then fail "link from a missing source should fail"; fi
if [ -e "$dest" ] || [ -L "$dest" ]; then fail "a link was created for a missing source"; fi
grep -q 'source missing' "$warnlog" || fail "missing-source used the wrong warning"

# --- 8. Symlink pointing at a directory: treated as a symlink, replaced ------
# [ -d ] is true *through* a symlink-to-dir, but link()'s -L branch runs before
# its -d branch, so this is repointed without a backup - the loud directory
# refusal is reserved for a *real* directory at the target.
dest="$work/symlink_to_dir"
mkdir "$work/realdir"
ln -s "$work/realdir" "$dest"
link "$src" "$dest" || fail "relink over a symlink-to-directory returned non-zero"
[ "$(readlink "$dest")" = "$src" ] || fail "symlink-to-directory not repointed"
if [ -e "$dest.bak" ]; then fail "symlink-to-directory replacement created a .bak"; fi
[ -d "$work/realdir" ] || fail "the pointed-at directory was disturbed"

# --- 9. Existing .bak present: refuse rather than destroy it ---
# The first backup is the pristine pre-framework file; a second real file at the
# target must not clobber it. link() refuses loudly and leaves both files as-is.
dest="$work/twice"
printf 'pristine original\n' > "$dest.bak"   # backup from an earlier install
printf 'new real file\n' > "$dest"           # user replaced the link with a file
: > "$warnlog"
if link "$src" "$dest"; then fail "link should refuse when a .bak already exists"; fi
[ "$(cat "$dest.bak")" = "pristine original" ] || fail "existing .bak was overwritten"
{ [ -e "$dest" ] && [ ! -L "$dest" ]; } || fail "the new real file was disturbed on refusal"
grep -q 'backup already exists' "$warnlog" || fail "backup-collision refusal used the wrong warning"

echo "PASS: link_test"
