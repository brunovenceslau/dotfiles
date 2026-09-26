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
# Prune acts only under $HOME; pin it into the workspace, never the real one.
export HOME="$work"

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

# --- 4. A symlink pointing outside the repo: the user's, backed up as a link --
# ROOT is omitted: with no repo to judge against, nothing counts as in-repo.
dest="$work/wrong_symlink"
ln -s "$work/other" "$dest"
link "$src" "$dest" || fail "relink over a foreign symlink returned non-zero"
[ "$(readlink "$dest")" = "$src" ] || fail "foreign symlink not repointed"
[ -L "$dest.bak" ] || fail "foreign symlink not backed up to .bak as a symlink"
[ "$(readlink "$dest.bak")" = "$work/other" ] || fail ".bak lost the original link target"

# --- 5. Dangling foreign symlink: backed up as the same dangling link ---------
dest="$work/dangling"
ln -s "$work/nonexistent" "$dest"
{ [ -L "$dest" ] && [ ! -e "$dest" ]; } || fail "test setup: dest is not dangling"
link "$src" "$dest" || fail "relink over a dangling symlink returned non-zero"
[ "$(readlink "$dest")" = "$src" ] || fail "dangling symlink not replaced"
[ -L "$dest.bak" ] || fail "dangling foreign symlink not backed up"
[ "$(readlink "$dest.bak")" = "$work/nonexistent" ] || fail "dangling .bak lost its target"

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

# --- 8. Symlink pointing at a directory: treated as a symlink, not a dir ------
# [ -d ] is true *through* a symlink-to-dir, but link()'s -L branch runs before
# its -d branch, so this is backed up as a link - the loud directory refusal is
# reserved for a *real* directory at the target.
dest="$work/symlink_to_dir"
mkdir "$work/realdir"
ln -s "$work/realdir" "$dest"
link "$src" "$dest" || fail "relink over a symlink-to-directory returned non-zero"
[ "$(readlink "$dest")" = "$src" ] || fail "symlink-to-directory not repointed"
[ "$(readlink "$dest.bak")" = "$work/realdir" ] || fail "symlink-to-directory not backed up as a link"
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

# --- 10. In-repo classification, with a real repo ROOT ------------------------
# The repo is reached through a symlinked alias as well as its physical path, the
# way ~/.config/dotfiles and ~/src/... can name one checkout. A sibling whose name
# extends the repo's (<repo>-host) is the prefix lookalike that must stay outside.
repo="$(cd "$work" && pwd -P)/repo"
mkdir -p "$repo/config/tmux" "$repo-host/config"
printf 'rsrc\n' > "$repo/zshrc"
ln -s "$repo" "$work/alias"
home="$work/home10"; mkdir -p "$home/.config"

# 10a. A stale framework link (absolute, into the repo): replaced, no .bak.
dest="$home/stale"; ln -s "$repo/config/tmux" "$dest"
link "$repo/zshrc" "$dest" "$repo" || fail "10a: relink over a stale framework link failed"
[ "$(readlink "$dest")" = "$repo/zshrc" ] || fail "10a: stale framework link not repointed"
if [ -e "$dest.bak" ] || [ -L "$dest.bak" ]; then fail "10a: an in-repo link was backed up"; fi

# 10b. A dangling link into the repo (its source was removed): still ours.
dest="$home/stale_dangling"; ln -s "$repo/config/gone/deeper" "$dest"
link "$repo/zshrc" "$dest" "$repo" || fail "10b: relink over a dangling in-repo link failed"
if [ -e "$dest.bak" ] || [ -L "$dest.bak" ]; then fail "10b: a dangling in-repo link was backed up"; fi

# 10c. A RELATIVE target into the repo resolves against the link's own directory.
dest="$home/.config/rel"
ln -s "../../repo/config/tmux" "$dest"
[ -d "$dest" ] || fail "10c: test setup: relative link does not resolve into the repo"
link "$repo/zshrc" "$dest" "$repo" || fail "10c: relink over a relative in-repo link failed"
if [ -e "$dest.bak" ] || [ -L "$dest.bak" ]; then fail "10c: a relative in-repo link was backed up"; fi

# 10d. A target spelled through the symlinked alias of the checkout: in-repo.
dest="$home/via_alias"; ln -s "$work/alias/config/tmux" "$dest"
link "$repo/zshrc" "$dest" "$repo" || fail "10d: relink over an aliased in-repo link failed"
if [ -e "$dest.bak" ] || [ -L "$dest.bak" ]; then fail "10d: an aliased in-repo link was backed up"; fi

# 10e. ROOT itself given as the alias: classification is still physical.
dest="$home/root_alias"; ln -s "$repo/config/tmux" "$dest"
link "$repo/zshrc" "$dest" "$work/alias" || fail "10e: relink with an aliased ROOT failed"
if [ -e "$dest.bak" ] || [ -L "$dest.bak" ]; then fail "10e: aliased ROOT misclassified an in-repo link"; fi

# 10f. The prefix lookalike (<repo>-host) is outside the repo: backed up.
dest="$home/lookalike"; ln -s "$repo-host/config" "$dest"
link "$repo/zshrc" "$dest" "$repo" || fail "10f: relink over a lookalike link failed"
[ "$(readlink "$dest.bak")" = "$repo-host/config" ] || fail "10f: prefix lookalike classified in-repo"

# 10g. A dangling user link outside the repo, relative: backed up verbatim.
dest="$home/.config/mine"; ln -s "../my-dots/nvim" "$dest"
link "$repo/zshrc" "$dest" "$repo" || fail "10g: relink over a dangling relative user link failed"
[ "$(readlink "$dest.bak")" = "../my-dots/nvim" ] || fail "10g: relative user link not backed up verbatim"

# 10h. A missing component followed by .. cannot be resolved honestly: it is
# never counted as in-repo, whatever it lexically collapses to.
dest="$home/dotdot"; ln -s "$repo/missing/../config/tmux" "$dest"
link "$repo/zshrc" "$dest" "$repo" || fail "10h: relink over an unresolvable link failed"
[ -L "$dest.bak" ] || fail "10h: an unresolvable target was classified in-repo"

# --- 11. The first .bak of a symlink is pristine: never overwritten ------------
# Run 1 backed up the user's link (10f). The user puts another link back; run 2
# must refuse and leave both untouched.
dest="$home/lookalike"
rm -f -- "$dest"; ln -s "$work/second" "$dest"
: > "$warnlog"
if link "$repo/zshrc" "$dest" "$repo"; then fail "11: link must refuse when a .bak already exists"; fi
[ "$(readlink "$dest.bak")" = "$repo-host/config" ] || fail "11: the pristine symlink .bak was overwritten"
[ "$(readlink "$dest")" = "$work/second" ] || fail "11: the user's second link was disturbed on refusal"
grep -q 'backup already exists' "$warnlog" || fail "11: backup-collision refusal used the wrong warning"

# 11b. The pristine .bak is a DANGLING link ([ -e ] is false for it): still kept.
dest="$home/dangling_bak"
ln -s "$work/nonexistent-orig" "$dest.bak"
printf 'a later real file\n' > "$dest"
if link "$repo/zshrc" "$dest" "$repo"; then fail "11b: link must refuse over a dangling .bak"; fi
[ "$(readlink "$dest.bak")" = "$work/nonexistent-orig" ] || fail "11b: a dangling pristine .bak was overwritten"

# --- 12. Prune keeps the manifest consistent when it cannot finish -------------
# An orphan whose unlink fails (unwritable parent) stays recorded, so a later
# uninstall can still remove it and restore its .bak. Non-root only: permissions
# do not bind root.
if [ "$(id -u)" -ne 0 ]; then
  d12="$work/home12/locked"; mkdir -p "$d12"
  ln -s "$repo/config/tmux" "$d12/orphan"
  printf 'pristine\n' > "$d12/orphan.bak"
  man12="$work/home12/manifest"; printf '%s\n' "$d12/orphan" > "$man12"
  LINK_MANIFEST="$work/home12/scratch"; : > "$LINK_MANIFEST"
  # The kept entry keeps its pair; this run's own pair is published beside it.
  LINK_TARGETS="$work/home12/targets" LINK_TARGETS_SCRATCH="$work/home12/tscratch"
  printf '%s\t%s\n' "$d12/orphan" "$repo/config/tmux" > "$LINK_TARGETS"
  printf '%s\n' "$work/home12/live" >> "$LINK_MANIFEST"
  printf '%s\t%s\n' "$work/home12/live" "$repo/zshrc" > "$LINK_TARGETS_SCRATCH"
  : > "$warnlog"
  chmod a-w "$d12"
  link_manifest_finalize "$man12" "$repo" 2>/dev/null || { chmod u+w "$d12"; fail "12: finalize returned non-zero"; }
  chmod u+w "$d12"
  unset LINK_MANIFEST
  [ -L "$d12/orphan" ] || fail "12: test setup: the unlink was expected to fail"
  grep -qxF "$d12/orphan" "$man12" || fail "12: an orphan prune could not remove was dropped from the manifest"
  [ "$(cat "$d12/orphan.bak")" = "pristine" ] || fail "12: the .bak of an unremoved orphan was touched"
  grep -q "could not remove orphan link $d12/orphan" "$warnlog" || fail "12: the failed prune was not reported"
  [ "$(cat "$LINK_TARGETS")" = "$(printf '%s\t%s\n%s\t%s' "$work/home12/live" "$repo/zshrc" "$d12/orphan" "$repo/config/tmux")" ] \
    || fail "12: the targets file does not hold exactly the kept and the new pair"
  unset LINK_TARGETS LINK_TARGETS_SCRATCH
else
  echo "SKIP: link_test case 12 (running as root)"
fi

# --- 13. Pairs: a tab or newline is never recorded, and never matches ----------
LINK_MANIFEST="$work/m13"; : > "$LINK_MANIFEST"
LINK_TARGETS="$work/t13"; LINK_TARGETS_SCRATCH="$work/s13"; : > "$LINK_TARGETS_SCRATCH"
tabdir="$work/tab$(printf '\t')dir"; mkdir -p "$tabdir"
: > "$warnlog"
link "$src" "$tabdir/dest" || fail "13: link into a tab-named dir failed"
grep -qxF "$tabdir/dest" "$LINK_MANIFEST" || fail "13: the manifest entry was not recorded"
[ ! -s "$LINK_TARGETS_SCRATCH" ] || fail "13: a pair with a tab was recorded"
grep -q 'not recording the target of' "$warnlog" || fail "13: the refused pair was not reported"
# A forged pair file naming the tab path cannot make it framework-owned: the
# lookup refuses the unsafe path before it searches.
rm -f -- "$tabdir/dest"; ln -s "$work/elsewhere" "$tabdir/dest"
printf '%s\t%s\n' "$tabdir/dest" "$work/elsewhere" > "$LINK_TARGETS"
link "$src" "$tabdir/dest" || fail "13: relink over the tab-path link failed"
[ "$(readlink "$tabdir/dest.bak")" = "$work/elsewhere" ] || fail "13: an unsafe path matched a pair"
# A live target ending in a newline must not pass for the recorded one without it.
dest="$work/nl13"; ln -s "$work/elsewhere$(printf '\nx')" "$dest"
t13="$(readlink "$dest")"; t13="${t13%x}"; rm -f -- "$dest"; ln -s "$t13" "$dest"
printf '%s\t%s\n' "$dest" "$work/elsewhere" > "$LINK_TARGETS"
link "$src" "$dest" || fail "13: relink over a newline-target link failed"
[ -L "$dest.bak" ] || fail "13: a target with a trailing newline matched the pair without it"
unset LINK_MANIFEST LINK_TARGETS LINK_TARGETS_SCRATCH

# --- 14. _link_git: a ".." target out of the repo is foreign at both sites ------
mkdir -p "$repo/config/git" "$work/mine14/gitdir"
printf '[core]\n' > "$repo/config/git/config"
printf 'theirs\n' > "$work/mine14/config"
cfg14="$work/home14a/.config"; mkdir -p "$cfg14"
ln -s "$repo/../mine14/gitdir" "$cfg14/git"
_link_git "$repo/config/git" "$cfg14" "$repo" || fail "14: _link_git over a foreign dir link failed"
[ "$(readlink "$cfg14/git")" = "$repo/../mine14/gitdir" ] || fail "14: _link_git removed a .. dir link out of the repo"
cfg14="$work/home14b/.config"; mkdir -p "$cfg14/git"
ln -s "$repo/../mine14/config" "$cfg14/git/config"
_link_git "$repo/config/git" "$cfg14" "$repo" || fail "14: _link_git over a foreign config link failed"
[ "$(readlink "$cfg14/git/config")" = "$repo/../mine14/config" ] || fail "14: _link_git removed a .. config link out of the repo"
# The same site still converts a real link into the repo.
cfg14="$work/home14c/.config"; mkdir -p "$cfg14/git"
ln -s "$repo/config/git/config" "$cfg14/git/config"
_link_git "$repo/config/git" "$cfg14" "$repo" || fail "14: _link_git over its own stale link failed"
{ [ -f "$cfg14/git/config" ] && [ ! -L "$cfg14/git/config" ]; } || fail "14: the stale in-repo config link was not converted"

# --- 15. Prune's "something occupies DEST" branch: a race after the rm ---------
# Reachable only if something recreates DEST between prune's rm and the restore;
# an rm wrapper stages exactly that race. The .bak and the intruder both stay,
# and the entry stays recorded for a later uninstall.
d15="$work/home15"; mkdir -p "$d15"
ln -s "$repo/config/tmux" "$d15/orphan"; printf 'pristine\n' > "$d15/orphan.bak"
man15="$d15/manifest"; printf '%s\n' "$d15/orphan" > "$man15"
LINK_MANIFEST="$d15/scratch"; : > "$LINK_MANIFEST"
rm() { command rm "$@"; local a; for a in "$@"; do [ "$a" != "$d15/orphan" ] || printf 'raced\n' > "$a"; done; }
: > "$warnlog"
link_manifest_finalize "$man15" "$repo" || { unset -f rm; fail "15: finalize returned non-zero"; }
unset -f rm; unset LINK_MANIFEST
[ "$(cat "$d15/orphan")" = "raced" ] || fail "15: the file that raced into DEST was clobbered"
[ "$(cat "$d15/orphan.bak")" = "pristine" ] || fail "15: the .bak was consumed over an occupied DEST"
grep -qxF "$d15/orphan" "$man15" || fail "15: the unfinished entry was dropped from the manifest"
grep -q "not restoring $d15/orphan.bak - something occupies" "$warnlog" || fail "15: the occupied DEST was not reported"

# --- 16. A symlinked targets file is never followed ----------------------------
# A forged pair behind a symlinked $LINK_TARGETS must not make a foreign link the
# framework's; the next publish renames a real file over the symlink and leaves
# what it pointed at alone.
d16="$work/home16"; mkdir -p "$d16"
ln -s "$work/elsewhere16" "$d16/dest"
printf '%s\t%s\n' "$d16/dest" "$work/elsewhere16" > "$d16/forged"
ln -s "$d16/forged" "$d16/targets"
LINK_MANIFEST="$d16/scratch"; : > "$LINK_MANIFEST"
LINK_TARGETS="$d16/targets" LINK_TARGETS_SCRATCH="$d16/tscratch"; : > "$LINK_TARGETS_SCRATCH"
_link_targets_warned=""; : > "$warnlog"
link "$src" "$d16/dest" || fail "16: relink with a symlinked targets file failed"
[ "$(readlink "$d16/dest.bak")" = "$work/elsewhere16" ] || fail "16: a pair behind a symlinked targets file was trusted"
grep -q "is a symlink - ignoring it" "$warnlog" || fail "16: the symlinked targets file was not reported"
link_manifest_finalize "$d16/manifest" || fail "16: finalize failed"
{ [ -f "$d16/targets" ] && [ ! -L "$d16/targets" ]; } || fail "16: publish did not replace the symlinked targets file"
[ "$(cat "$d16/forged")" = "$(printf '%s\t%s' "$d16/dest" "$work/elsewhere16")" ] || fail "16: publish wrote through the symlink"
unset LINK_MANIFEST LINK_TARGETS LINK_TARGETS_SCRATCH

# --- 17. A backslash in the state path does not bend the targets merge ---------
# "\\t" is a backslash then a "t": every awk -v turns it into a tab.
d17="$work/back\\tslash17"; mkdir -p "$d17"
printf '%s\n' "$d17/x" > "$d17/manifest"
printf '%s\t%s\n' "$d17/x" "/old" > "$d17/targets"
LINK_MANIFEST="$d17/scratch"; printf '%s\n' "$d17/x" > "$LINK_MANIFEST"
LINK_TARGETS="$d17/targets" LINK_TARGETS_SCRATCH="$d17/tscratch"
printf '%s\t%s\n' "$d17/x" "/new" > "$LINK_TARGETS_SCRATCH"
link_manifest_merge "$d17/manifest" || fail "17: merge failed"
[ "$(cat "$d17/targets")" = "$(printf '%s\t%s' "$d17/x" "/new")" ] || fail "17: a backslash path kept a stale pair beside the new one"
unset LINK_MANIFEST LINK_TARGETS LINK_TARGETS_SCRATCH

# --- 18. Prune refuses manifest lines it may not act on, and says so -----------
# Lines it may not act on: out of $HOME (a), spelled "$HOME/../" (b), through a
# symlinked parent into the checkout (d). Where something is there (the link or
# its .bak): no removal, no restore, kept with its own warning, and finalize
# returns 2 after publishing. Where nothing is there (c): dropped, warned.
(
  export HOME="$work/home18"; mkdir -p "$HOME" "$work/out18" "$repo/config/inner18"
  ln -s "$repo/config/tmux" "$work/out18/a"; printf 'a\n' > "$work/out18/a.bak"
  ln -s "$repo/config/tmux" "$work/out18/b"; printf 'b\n' > "$work/out18/b.bak"
  ln -s "$repo/config/tmux" "$repo/config/inner18/d"
  ln -s "$repo/config/inner18" "$HOME/.inner"
  man="$HOME/manifest"
  printf '%s\n' "$work/out18/a" "$HOME/../out18/b" "$work/out18/c" "$HOME/.inner/d" > "$man"
  LINK_MANIFEST="$HOME/scratch"; : > "$LINK_MANIFEST"
  : > "$warnlog"
  rc=0; link_manifest_finalize "$man" "$repo" || rc=$?
  [ "$rc" -eq 2 ] || { echo "18: a kept refusal must make finalize return 2 (got $rc)"; exit 1; }
  for x in a b; do
    [ -L "$work/out18/$x" ] || { echo "18: prune removed $x outside \$HOME"; exit 1; }
    [ "$(cat "$work/out18/$x.bak")" = "$x" ] || { echo "18: prune restored $x.bak outside \$HOME"; exit 1; }
  done
  [ -L "$repo/config/inner18/d" ] || { echo "18: prune removed a file inside the checkout through a symlinked parent"; exit 1; }
  for x in "$work/out18/a" "$HOME/../out18/b" "$HOME/.inner/d"; do
    grep -qxF "$x" "$man" || { echo "18: $x was dropped although something is there"; exit 1; }
  done
  grep -qxF "$work/out18/c" "$man" && { echo "18: a line with nothing on disk was kept"; exit 1; }
  # Each refusal names its own reason: the two out of $HOME, and d (reached
  # through a parent inside the checkout) as the checkout, never as "outside".
  for x in "$work/out18/a" "$HOME/../out18/b"; do
    grep -qxF "prune: keeping $x recorded - outside the home directory, and something is there" "$warnlog" \
      || { echo "18: the kept refusal of $x did not say outside the home directory"; exit 1; }
  done
  grep -qxF "prune: keeping $HOME/.inner/d recorded - inside the checkout, and something is there" "$warnlog" \
    || { echo "18: the kept refusal of d did not say inside the checkout"; exit 1; }
  [ "$(grep -c '^prune: keeping ' "$warnlog")" -eq 3 ] || { echo "18: expected exactly 3 kept refusals"; exit 1; }
  grep -q "prune: dropping $work/out18/c from the manifest - outside the home directory, and nothing is there" "$warnlog" \
    || { echo "18: the dropped line was not reported"; exit 1; }
  rm -f -- "$HOME/.inner"
) || fail "prune containment regressed"

# --- 19. Prune with no link at DEST: a missing DEST gets its .bak back ----------
# (the user deleted the link), a real file at DEST keeps its .bak and its entry.
d19="$work/home19"; mkdir -p "$d19"
printf 'orig\n' > "$d19/gone.bak"                      # DEST missing, .bak present
printf 'mine\n' > "$d19/real"; printf 'orig\n' > "$d19/real.bak"   # a real file replaced the link
printf 'mine\n' > "$d19/plain"                        # a real file, no .bak
man19="$d19/manifest"; printf '%s\n' "$d19/gone" "$d19/real" "$d19/plain" > "$man19"
LINK_MANIFEST="$d19/scratch"; : > "$LINK_MANIFEST"
: > "$warnlog"
link_manifest_finalize "$man19" "$repo" || fail "19: finalize returned non-zero"
unset LINK_MANIFEST
[ "$(cat "$d19/gone")" = "orig" ] || fail "19: a .bak with no DEST was not restored"
if [ -e "$d19/gone.bak" ]; then fail "19: the restored .bak was not consumed"; fi
grep -qxF "$d19/gone" "$man19" && fail "19: a restored entry is still recorded"
[ "$(cat "$d19/real")" = "mine" ] && [ "$(cat "$d19/real.bak")" = "orig" ] || fail "19: the user's real file or its .bak was touched"
grep -qxF "$d19/real" "$man19" || fail "19: a real file with a .bak was dropped from the manifest"
grep -q "prune: $d19/real is not our symlink anymore - keeping it and its .bak recorded" "$warnlog" \
  || fail "19: the kept real file was not reported"
grep -qxF "$d19/plain" "$man19" && fail "19: a real file with no .bak is still recorded"
[ "$(cat "$d19/plain")" = "mine" ] || fail "19: a real file with no .bak was touched"

# --- 20. _link_targets_discard drops a staged file, and is a no-op without one --
_link_targets_tmp="$work/staged20"; printf 'x\n' > "$_link_targets_tmp"
_link_targets_discard
[ ! -e "$work/staged20" ] || fail "20: discard left the staged targets file"
[ -z "$_link_targets_tmp" ] || fail "20: discard did not clear the staged path"
_link_targets_discard || fail "20: discard with nothing staged failed"

# --- 21. Containment on the install side (link() and _link_under_home) ---------
(
  export HOME="$work/home21"; mkdir -p "$HOME" "$work/away21" "$repo/config/inner21"
  : > "$warnlog"
  # A symlinked parent out of $HOME, and one into the checkout: refused, nothing made.
  ln -s "$work/away21" "$HOME/.away"; ln -s "$repo/config/inner21" "$HOME/.inner"
  for d in "$HOME/.away/x" "$HOME/.inner/x"; do
    if link "$src" "$d" "$repo"; then echo "21: link() accepted $d"; exit 1; fi
  done
  [ ! -e "$work/away21/x" ] && [ ! -L "$work/away21/x" ] || { echo "21: link() wrote outside \$HOME"; exit 1; }
  [ ! -L "$repo/config/inner21/x" ] || { echo "21: link() wrote into the checkout"; exit 1; }
  grep -qxF "link: refusing $HOME/.away/x - outside the home directory" "$warnlog" || { echo "21: the refusal out of \$HOME was not reported as such"; exit 1; }
  grep -qxF "link: refusing $HOME/.inner/x - inside the checkout" "$warnlog" || { echo "21: the refusal into the checkout was not reported as such"; exit 1; }
  # A destination ending in "/", and a relative $HOME: refused.
  _link_under_home "$HOME/x/" && { echo "21: a trailing-slash path was accepted"; exit 1; }
  ( cd "$work" && HOME="home21" _link_under_home "home21/x" ) && { echo "21: a relative HOME was accepted"; exit 1; }
  # PATH itself the checkout, or an ancestor of it: refused.
  mkdir -p "$HOME/anc/zsh/repo21"
  _link_under_home "$HOME/anc/zsh/repo21" "$HOME/anc/zsh/repo21" && { echo "21: PATH = ROOT accepted"; exit 1; }
  _link_under_home "$HOME/anc/zsh" "$HOME/anc/zsh/repo21" && { echo "21: PATH an ancestor of ROOT accepted"; exit 1; }
  _link_under_home "$HOME/anc/other" "$HOME/anc/zsh/repo21" || { echo "21: a sibling of ROOT refused"; exit 1; }
  # A failed ln (the parent is a dangling symlink) returns 1 and records nothing.
  LINK_MANIFEST="$HOME/scratch21"; : > "$LINK_MANIFEST"
  ln -s "$HOME/nowhere" "$HOME/.dangling"
  if link "$src" "$HOME/.dangling/x" "$repo" 2>/dev/null; then echo "21: link() under a dangling parent succeeded"; exit 1; fi
  [ ! -s "$LINK_MANIFEST" ] || { echo "21: a link that was never made was recorded"; exit 1; }
  exit 0
) || fail "install-side containment regressed"

# --- 22. $HOME inside the checkout (the make smoke carve-out) -------------------
# Everything under such a HOME is "inside ROOT", and is allowed; a symlinked
# parent that leaves that HOME for the rest of the checkout is still refused.
(
  export HOME="$repo/.smoke22/home"; mkdir -p "$HOME" "$repo/config/inner22"
  link "$src" "$HOME/.config/x" "$repo" || { echo "22: a HOME inside the checkout refused its own destination"; exit 1; }
  ln -s "$repo/config/inner22" "$HOME/.out"
  if link "$src" "$HOME/.out/x" "$repo" 2>/dev/null; then echo "22: a parent leaving the in-checkout HOME was accepted"; exit 1; fi
  exit 0
) || fail "HOME-inside-ROOT carve-out regressed"

echo "PASS: link_test"
