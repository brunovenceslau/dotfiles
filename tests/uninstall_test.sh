#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for lib/uninstall.sh - the manifest-driven reverse of the link
# engine. Asserts that it removes ONLY manifest-listed links that are still
# ours, restores *.bak and touches nothing else, and that --purge clears
# generated state/cache but never a user `.local`. Fully hermetic: a mktemp
# fixture repo + a mktemp scratch HOME, like tests/link_engine_test.sh; never
# touches the real $HOME. Not part of the shellcheck surface.
#
# Bash 3.2 compatible (no associative arrays, no mapfile, no ${var,,}).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/uninstall_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Caller contract lib/link.sh + lib/uninstall.sh expect: log()/warn() and $DOTFILES.
# Silence log/warn so the test output stays clean; the manifest is the real signal.
log()  { :; }
warn() { :; }
export DOTFILES="$work/repo"
export HOME="$work/home"
# Pin XDG_CONFIG_HOME into the workspace too. uninstall_purge's .local-home guard
# resolves ${XDG_CONFIG_HOME:-$HOME/.config}/zsh, so an inherited XDG_CONFIG_HOME
# (a CI runner sets one) would point the guard away from this test's $HOME/.config
# and the containment assertion below would misfire - exporting it keeps the whole
# test hermetic, matching install_cli_test.sh and link_engine_test.sh.
export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$DOTFILES" "$HOME"

# shellcheck source=lib/link.sh
. "$repo_root/lib/link.sh"
# shellcheck source=lib/uninstall.sh
. "$repo_root/lib/uninstall.sh"

# Fixture source files in the repo, and the manifest the installer would write.
printf 'rc\n'  > "$DOTFILES/zshrc"
printf 'tool\n'> "$DOTFILES/tool"
manifest_dir="$HOME/.local/state/dotfiles"
manifest="$manifest_dir/manifest"
mkdir -p "$manifest_dir"

# --- Build the on-disk state via the real link() so the test mirrors install ---
LINK_MANIFEST="$(mktemp "$manifest_dir/.m.XXXXXX")"
link "$DOTFILES/zshrc" "$HOME/.config/zsh/.zshrc"       # a normal conventional link
# A pre-existing user file that must be backed up now and restored on uninstall.
mkdir -p "$HOME/.local/bin"
printf 'USER ORIGINAL\n' > "$HOME/.local/bin/tool"
link "$DOTFILES/tool" "$HOME/.local/bin/tool"           # backs up -> tool.bak
link_manifest_finalize "$manifest"
rm -f -- "$LINK_MANIFEST"; unset LINK_MANIFEST

[ -L "$HOME/.config/zsh/.zshrc" ] || fail "setup: .zshrc link not created"
[ -f "$HOME/.local/bin/tool.bak" ] || fail "setup: pre-existing tool not backed up"

# A user .local sitting beside a link - must survive uninstall AND keep its dir.
printf 'local\n' > "$HOME/.config/zsh/.zshrc.local"

# Tamper cases the uninstall MUST refuse to delete: a manifest entry the user has
# since replaced with their own regular file, and one repointed outside the repo.
printf 'not ours\n' > "$HOME/replaced-by-user"
printf '%s\n' "$HOME/replaced-by-user" >> "$manifest"
ln -s /etc/hostname "$HOME/points-elsewhere"
printf '%s\n' "$HOME/points-elsewhere" >> "$manifest"
LC_ALL=C sort -u "$manifest" -o "$manifest"

# --- uninstall_links ----------------------------------------------------------
uninstall_links "$manifest" || fail "uninstall_links returned nonzero"

# Our links are gone...
[ ! -e "$HOME/.config/zsh/.zshrc" ] || fail "our .zshrc link was not removed"
# ...the backed-up user file is restored to the original content, .bak consumed...
[ -f "$HOME/.local/bin/tool" ] && [ ! -L "$HOME/.local/bin/tool" ] \
  || fail "backed-up file not restored as a regular file"
[ "$(cat "$HOME/.local/bin/tool")" = "USER ORIGINAL" ] || fail "restored file has wrong content"
[ ! -e "$HOME/.local/bin/tool.bak" ] || fail ".bak not consumed on restore"
# ...the user's .local and its dir survive (empty-dir pruning must stop there)...
[ -f "$HOME/.config/zsh/.zshrc.local" ] || fail ".zshrc.local was removed (must never happen)"
[ -d "$HOME/.config/zsh" ] || fail "dir holding a .local was pruned"
# ...and the two tamper entries are untouched.
[ -f "$HOME/replaced-by-user" ] && [ ! -L "$HOME/replaced-by-user" ] \
  || fail "a manifest path the user replaced with a real file was deleted"
[ -L "$HOME/points-elsewhere" ] || fail "a manifest link pointing outside the repo was deleted"

# A .bak whose dest is re-occupied by the user must NOT be force-restored over it.
occ="$HOME/occupied"
printf 'PRE-FRAMEWORK\n' > "$occ.bak"           # a stale backup...
printf 'USER PUT THIS BACK\n' > "$occ"          # ...and the user has since re-created dest
printf '%s\n' "$occ" >> "$manifest"; LC_ALL=C sort -u "$manifest" -o "$manifest"
uninstall_links "$manifest" || fail "uninstall_links (occupied-dest case) returned nonzero"
[ "$(cat "$occ")" = "USER PUT THIS BACK" ] || fail "occupied dest was clobbered by a stale .bak restore"
[ -f "$occ.bak" ] || fail "the stale .bak was consumed even though dest was occupied"

# Empty-dir pruning: ~/.local/bin held only the restored file (still there), so it
# stays; but a purely-empty chain must be gone. .config/zsh stays (holds .local).
rm -f "$HOME/.local/bin/tool"                 # remove the restored file...
rmdir "$HOME/.local/bin" 2>/dev/null || true  # ...prove nothing else lingers there
[ ! -e "$HOME/.local/bin/keep" ] || fail "unexpected leftover in ~/.local/bin"

# --- uninstall_purge ----------------------------------------------------------
# Generated trees to purge, plus a .local under config/zsh that must NOT be purged.
export XDG_CACHE_HOME="$HOME/.cache" XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$XDG_CACHE_HOME/zsh/fast-syntax-highlighting" "$XDG_STATE_HOME/zsh" "$XDG_STATE_HOME/dotfiles"
printf 'hist\n' > "$XDG_STATE_HOME/zsh/history"
printf 'dump\n' > "$XDG_CACHE_HOME/zsh/zcompdump"

uninstall_purge || fail "uninstall_purge returned nonzero"

[ ! -e "$XDG_CACHE_HOME/zsh" ]        || fail "purge left \$XDG_CACHE_HOME/zsh"
[ ! -e "$XDG_STATE_HOME/zsh" ]        || fail "purge left \$XDG_STATE_HOME/zsh"
[ ! -e "$XDG_STATE_HOME/dotfiles" ]   || fail "purge left \$XDG_STATE_HOME/dotfiles"
[ -f "$HOME/.config/zsh/.zshrc.local" ] || fail "purge removed a user .local"

# --- purge containment (ship hardening) ----------------------------------------
# A mispointed XDG var must never turn --purge into an out-of-HOME rm -rf, and the
# .local home ($XDG_CONFIG_HOME/zsh) is refused even when an XDG var derives to it.
mkdir -p "$work/xdg-evil/zsh"; printf 'x\n' > "$work/xdg-evil/zsh/f"
if XDG_STATE_HOME="$work/xdg-evil" XDG_CACHE_HOME="$work/xdg-evil" uninstall_purge 2>/dev/null; then
  fail "purge accepted an out-of-HOME XDG tree (containment guard missing)"
fi
[ -f "$work/xdg-evil/zsh/f" ] || fail "purge removed an out-of-HOME tree it should refuse"
if XDG_STATE_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.config" uninstall_purge 2>/dev/null; then
  fail "purge accepted the .local home via a mispointed XDG var"
fi
[ -f "$HOME/.config/zsh/.zshrc.local" ] || fail "purge deleted the .local layer via a mispointed XDG var"

# --- purge never reaches into the checkout ---------------------------------------
# A checkout under $HOME, and XDG dirs that lead into it: a symlinked cache dir,
# the cache dir BEING the checkout, a cache dir whose zsh/ IS the checkout (its
# parent), and a state dir whose dotfiles/ IS the checkout. Each purge refuses
# (rc 1) and every file in the checkout survives.
purge_into() {  # CTX DOTFILES-dir [VAR=value...]
  local ctx="$1" dots="$2"; shift 2
  ( export DOTFILES="$dots" "$@"
    rc=0; uninstall_purge 2>/dev/null || rc=$?
    [ "$rc" -eq 1 ] || { echo "$ctx: purge into the checkout must return 1 (got $rc)"; exit 1; }
    [ -f "$dots/tracked" ] || { echo "$ctx: purge removed the checkout"; exit 1; }
    exit 0
  ) || fail "$ctx"
}
mkdir -p "$HOME/.config/dotfiles/cache/zsh"; : > "$HOME/.config/dotfiles/tracked"
: > "$HOME/.config/dotfiles/cache/zsh/keep"
ln -s "$HOME/.config/dotfiles/cache" "$HOME/.cache-into"
purge_into "symlinked cache dir" "$HOME/.config/dotfiles" XDG_CACHE_HOME="$HOME/.cache-into"
[ -f "$HOME/.config/dotfiles/cache/zsh/keep" ] || fail "purge removed a file inside the checkout through a symlinked cache dir"
mkdir -p "$HOME/.config/dotfiles/zsh"; : > "$HOME/.config/dotfiles/zsh/keep"
purge_into "cache dir = checkout" "$HOME/.config/dotfiles" XDG_CACHE_HOME="$HOME/.config/dotfiles"
[ -f "$HOME/.config/dotfiles/zsh/keep" ] || fail "purge removed the checkout's zsh/ with XDG_CACHE_HOME=\$DOTFILES"
mkdir -p "$HOME/p/zsh"; : > "$HOME/p/zsh/tracked"
purge_into "cache dir = parent of checkout" "$HOME/p/zsh" XDG_CACHE_HOME="$HOME/p"
mkdir -p "$HOME/.local/state/dotfiles"; : > "$HOME/.local/state/dotfiles/tracked"
purge_into "state dotfiles/ = checkout" "$HOME/.local/state/dotfiles" XDG_STATE_HOME="$HOME/.local/state"
rm -rf -- "$HOME/.config/dotfiles" "$HOME/.cache-into" "$HOME/p" "$HOME/.local/state/dotfiles"

# --- uninstall_links edge cases (ship hardening) ---------------------------------
mkdir -p "$manifest_dir"     # purge removed it above; the cases below need it back

# A dir-symlink (the config/<prog> convention): the LINK is removed, the repo
# content behind it must survive - the one bug class that would destroy the
# source of truth (an rm -rf or trailing slash would follow the link).
mkdir -p "$DOTFILES/config/alacritty"
printf 'cfg\n' > "$DOTFILES/config/alacritty/alacritty.toml"
mkdir -p "$HOME/.config"
ln -s "$DOTFILES/config/alacritty" "$HOME/.config/alacritty"
printf '%s\n' "$HOME/.config/alacritty" > "$manifest"
uninstall_links "$manifest" || fail "dir-symlink uninstall returned nonzero"
[ ! -e "$HOME/.config/alacritty" ] || fail "dir symlink was not removed"
[ -f "$DOTFILES/config/alacritty/alacritty.toml" ] \
  || fail "repo content was deleted THROUGH a dir symlink"

# A tampered manifest line outside $HOME is refused outright, even for a link
# into the repo: nothing there is removed or restored, and neither is a
# "$HOME/../" spelling that passes a bare prefix match.
mkdir -p "$work/outside" "$work/outside2"
ln -s "$DOTFILES/zshrc" "$work/outside/link"
printf 'theirs\n' > "$work/outside/link.bak"
ln -s "$DOTFILES/zshrc" "$work/outside2/link"
printf '%s\n%s\n' "$work/outside/link" "$HOME/../outside2/link" > "$manifest"
warnlog="$work/uwarn.log"; : > "$warnlog"
warn() { printf '%s\n' "$*" >> "$warnlog"; }
rc=0; uninstall_links "$manifest" || rc=$?
warn() { :; }
[ "$rc" -eq 1 ] || fail "an out-of-HOME refusal must make uninstall return 1 (got $rc)"
[ -L "$work/outside/link" ] || fail "a link outside \$HOME was removed"
[ "$(cat "$work/outside/link.bak")" = "theirs" ] || fail "a .bak outside \$HOME was restored"
[ -L "$work/outside2/link" ] || fail "a \$HOME/../ manifest line was acted on"
[ "$(grep -c 'outside the home directory' "$warnlog")" -eq 2 ] || fail "the out-of-HOME refusals were not reported"

# A target spelled with ".." out of the repo is not the repo's, whatever its
# prefix says: it is the user's and stays (the shared predicate, lib/link.sh).
mkdir -p "$work/elsewhere"
ln -s "$DOTFILES/../elsewhere" "$HOME/.dotdot"
printf '%s\n' "$HOME/.dotdot" > "$manifest"
uninstall_links "$manifest" || fail "dotdot uninstall returned nonzero"
[ -L "$HOME/.dotdot" ] || fail "uninstall removed a link whose target only lexically starts with the repo"
rm -f -- "$HOME/.dotdot"

# A RELATIVE link into the repo is the framework's too (operator decision
# 2026-09-26): uninstall removes it like the absolute one link() writes.
ln -s "../repo/zshrc" "$HOME/.relative"
[ -f "$HOME/.relative" ] || fail "test setup: the relative link does not resolve into the repo"
printf '%s\n' "$HOME/.relative" > "$manifest"
uninstall_links "$manifest" || fail "relative-link uninstall returned nonzero"
{ [ ! -e "$HOME/.relative" ] && [ ! -L "$HOME/.relative" ]; } || fail "a relative link into the repo was not removed"

# $HOME with a trailing slash names the same home: nothing is refused.
ln -s "$DOTFILES/zshrc" "$HOME/.slash"
printf '%s\n' "$HOME/.slash" > "$manifest"
HOME="$HOME/" uninstall_links "$manifest" || fail "a trailing-slash HOME made uninstall fail"
[ ! -L "$HOME/.slash" ] || fail "a trailing-slash HOME refused a link under it"
# $HOME of "/" contains nothing: refused, with rc 1.
ln -s "$DOTFILES/zshrc" "$HOME/.root"
printf '%s\n' "$HOME/.root" > "$manifest"
rc=0; HOME=/ uninstall_links "$manifest" || rc=$?
[ "$rc" -eq 1 ] || fail "HOME=/ must refuse every entry with rc 1 (got $rc)"
[ -L "$HOME/.root" ] || fail "HOME=/ let uninstall remove a link"
rm -f -- "$HOME/.root"

# A symlinked PARENT is resolved: uninstall never acts through one, whether it
# leads into the checkout (a directory link the framework made) or out of $HOME
# (a redirected directory). Both are refused with rc 1, nothing removed or restored.
mkdir -p "$DOTFILES/config/inner" "$work/away"
ln -s "$DOTFILES/zshrc" "$DOTFILES/config/inner/tracked-link"
ln -s "$DOTFILES/config/inner" "$HOME/.inner"
ln -s "$DOTFILES/zshrc" "$work/away/link"; printf 'away\n' > "$work/away/link.bak"
ln -s "$work/away" "$HOME/.away"
printf '%s\n%s\n' "$HOME/.inner/tracked-link" "$HOME/.away/link" > "$manifest"
rc=0; uninstall_links "$manifest" || rc=$?
[ "$rc" -eq 1 ] || fail "a symlinked parent must be refused with rc 1 (got $rc)"
[ -L "$DOTFILES/config/inner/tracked-link" ] || fail "uninstall removed a file inside the checkout through a symlinked parent"
[ -L "$work/away/link" ] || fail "uninstall removed a link outside \$HOME through a symlinked parent"
[ "$(cat "$work/away/link.bak")" = "away" ] || fail "uninstall restored a .bak outside \$HOME through a symlinked parent"
rm -f -- "$HOME/.inner" "$HOME/.away"

# A relative manifest line can only mean tampering/corruption - ignored, never
# resolved against the CWD (a .bak beside the CWD-relative path stays untouched).
mkdir -p "$work/cwdtest"
printf 'bait\n' > "$work/cwdtest/victim.bak"
printf '%s\n' "victim" > "$manifest"
( cd "$work/cwdtest" && uninstall_links "$manifest" 2>/dev/null ) \
  || fail "relative-line manifest returned nonzero"
[ ! -e "$work/cwdtest/victim" ] || fail "a relative manifest line was resolved against the CWD"
[ -f "$work/cwdtest/victim.bak" ] || fail "a .bak was consumed for a relative manifest line"

# Missing manifest: a warned no-op, exit 0 (the documented contract).
uninstall_links "$manifest_dir/does-not-exist" 2>/dev/null \
  || fail "missing manifest must be a no-op with exit 0"

# Empty / blank-lines-only manifest: exit 0, nothing touched.
printf '\n\n\n' > "$manifest"
uninstall_links "$manifest" || fail "blank-lines manifest must exit 0"

# A manifest path whose parent dir vanished: skipped cleanly, exit 0.
printf '%s\n' "$HOME/ghost/sub/link" > "$manifest"
uninstall_links "$manifest" || fail "vanished-parent manifest entry must exit 0"

# Final line without a trailing newline is still processed (the || [ -n ] guard).
ln -s "$DOTFILES/zshrc" "$HOME/.lastline"
printf '%s' "$HOME/.lastline" > "$manifest"
uninstall_links "$manifest" || fail "no-trailing-newline manifest returned nonzero"
[ ! -e "$HOME/.lastline" ] || fail "the final manifest line without a newline was silently skipped"

# A user symlink link() backed up (a relative, dangling target) is restored as
# THE SAME LINK - renamed back, never dereferenced or re-resolved - and the .bak
# is consumed. link() is the real one, so this also covers the backup half.
mkdir -p "$HOME/.config"
ln -s "../elsewhere/my-tmux" "$HOME/.config/tmux"
LINK_MANIFEST="$(mktemp "$manifest_dir/.m.XXXXXX")"
link "$DOTFILES/zshrc" "$HOME/.config/tmux" "$DOTFILES" || fail "symlink-backup setup: link failed"
link_manifest_finalize "$manifest"
rm -f -- "$LINK_MANIFEST"; unset LINK_MANIFEST
[ "$(readlink "$HOME/.config/tmux.bak")" = "../elsewhere/my-tmux" ] || fail "symlink-backup setup: no .bak link"
uninstall_links "$manifest" || fail "symlink-restore uninstall returned nonzero"
[ -L "$HOME/.config/tmux" ] || fail "the backed-up user symlink was not restored as a symlink"
[ "$(readlink "$HOME/.config/tmux")" = "../elsewhere/my-tmux" ] || fail "restored user symlink has a different target"
if [ -e "$HOME/.config/tmux.bak" ] || [ -L "$HOME/.config/tmux.bak" ]; then fail "symlink .bak not consumed"; fi
rm -f -- "$HOME/.config/tmux"

# A trailing newline is part of a link target: every uninstall decision and
# report must see it, under the host's readlink and under a shim that prints the
# macOS way (tests/lib/bsd_readlink.sh), where "T<newline>" reads like "T".
# shellcheck source=tests/lib/bsd_readlink.sh
. "$repo_root/tests/lib/bsd_readlink.sh"
bsd_readlink_shim "$work/bsdrl" || fail "the BSD readlink shim does not print a trailing-newline target the BSD way"
for rl in native bsd; do
  # A user link to "<recorded target><newline>" is not the recorded pair: left
  # in place, and the warning names its exact target.
  nld="$HOME/nl-pair-$rl"; ln -s "$work/outside$rl_nl" "$nld"
  LINK_TARGETS="$work/targets-$rl"; printf '%s\t%s\n' "$nld" "$work/outside" > "$LINK_TARGETS"
  # "<repo>/..<newline>" names an entry INSIDE the repo: the framework's, removed.
  nlr="$HOME/nl-repo-$rl"; ln -s "$DOTFILES/..$rl_nl" "$nlr"
  printf '%s\n%s\n' "$nld" "$nlr" > "$manifest"
  : > "$work/warn-$rl"
  warn() { printf '%s\n' "$*" >> "$work/warn-$rl"; }
  rc=0; rl_with "$rl" uninstall_links "$manifest" || rc=$?
  warn() { :; }; unset LINK_TARGETS
  [ "$rc" -eq 0 ] || fail "trailing-newline uninstall ($rl readlink) returned $rc"
  [ "$(readlink -n "$nld"; printf x)" = "$work/outside${rl_nl}x" ] \
    || fail "uninstall ($rl readlink) removed a user link to <recorded target><newline>"
  case "$(cat "$work/warn-$rl"; printf x)" in
    *"(-> $work/outside$rl_nl)"*) ;;
    *) fail "uninstall ($rl readlink): the warning lost the target's trailing newline" ;;
  esac
  { [ ! -e "$nlr" ] && [ ! -L "$nlr" ]; } \
    || fail "uninstall ($rl readlink) judged <repo>/..<newline> outside the repo"
  rm -f -- "$nld"
done

# --- exit-code fidelity through install.sh (non-root: perms don't bind root) ---
if [ "$(id -u)" -ne 0 ]; then
  # A removal that fails (unwritable parent dir) must surface as exit 1 - not 0
  # (swallowed) and not 2 (usage) - through do_uninstall and the dispatch.
  # install.sh self-resolves DOTFILES to the real repo, so the link must point
  # there for the still-ours guard to admit it to the rm attempt.
  deny="$HOME/deny"; mkdir -p "$deny"
  ln -s "$repo_root/zsh/zshrc" "$deny/link"
  mkdir -p "$manifest_dir"
  printf '%s\n' "$deny/link" > "$manifest"
  chmod a-w "$deny"
  rc=0; "$repo_root/install.sh" uninstall >/dev/null 2>&1 || rc=$?
  chmod u+w "$deny"
  [ "$rc" -eq 1 ] || fail "a failed removal must exit 1 through install.sh (got $rc)"

  # uninstall_purge propagates rc=1 when a tree cannot be removed.
  mkdir -p "$XDG_STATE_HOME/zsh"; printf 'h\n' > "$XDG_STATE_HOME/zsh/history"
  chmod a-w "$XDG_STATE_HOME/zsh"
  if uninstall_purge 2>/dev/null; then
    chmod -R u+w "$XDG_STATE_HOME" 2>/dev/null || true
    fail "purge must return nonzero when a tree cannot be removed"
  fi
  chmod -R u+w "$XDG_STATE_HOME" 2>/dev/null || true
else
  # Root: permissions do not bind, so the failed-removal cases cannot be staged,
  # and install.sh refuses root outright (tests/root_refusal_test.sh). CI runs
  # non-root.
  echo "SKIP: uninstall exit-code cases (running as root)"
fi

echo "PASS: uninstall_test"
