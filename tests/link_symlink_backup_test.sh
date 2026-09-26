#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# End-to-end test of the symlink backup contract through the REAL entry points
# (`install.sh link` and `install.sh uninstall` as subprocesses), the way a user
# hits it: a symlink of the user's own at a destination the framework links is
# backed up to .bak as the same link and restored by uninstall, while a stale
# framework link into the repo is replaced with no .bak and leaves nothing behind.
# A second checkout (B) then relinks over the first one's (A) links through the
# targets file: a recorded pair is the framework's, anything else is backed up.
# The unit-level cases (relative targets, aliases, lookalikes) live in
# tests/link_test.sh; this proves do_link wires the repo root and the targets
# file into link().
#
# Hermetic: scratch HOME + pinned XDG_* + neutralized git config, mktemp + trap;
# never touches the real $HOME. install.sh link writes only under HOME/XDG, so
# the checkout itself is used unmodified as A; B is a tar copy of it (tar, not
# cp: cp's fast-copy path can read zeros from a virtiofs-mounted checkout). Not
# on the shellcheck surface.
set -euo pipefail

# A privilege skip: install.sh refuses root for every subcommand, so nothing
# below can run as root (tests/root_refusal_test.sh covers that refusal).
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  echo "SKIP: link_symlink_backup_test (running as root: install.sh refuses root)"
  exit 0
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/link_symlink_backup_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
work="$(cd "$work" && pwd -P)"

export HOME="$work/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" \
       XDG_STATE_HOME="$HOME/.local/state"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$XDG_CONFIG_HOME" "$work/mine/tmux"

user_link="$XDG_CONFIG_HOME/tmux"        # the user's own link, outside the repo
stale_link="$XDG_CONFIG_HOME/nvim"       # a stale framework link, into the repo
ln -s "$work/mine/tmux" "$user_link"
ln -s "$repo_root/config/tmux" "$stale_link"

run() { "$repo_root/install.sh" "$@" >"$work/$1.log" 2>&1 || fail "install.sh $*: $(cat "$work/$1.log")"; }

# --- Run 1: the user's link is kept as a .bak, the stale one is just replaced ---
run link
[ "$(readlink "$user_link")" = "$repo_root/config/tmux" ] || fail "run 1: tmux not linked"
[ -L "$user_link.bak" ] || fail "run 1: the user's symlink was lost with no .bak"
[ "$(readlink "$user_link.bak")" = "$work/mine/tmux" ] || fail "run 1: .bak does not hold the original target"
[ "$(readlink "$stale_link")" = "$repo_root/config/nvim" ] || fail "run 1: stale nvim link not repointed"
if [ -e "$stale_link.bak" ] || [ -L "$stale_link.bak" ]; then fail "run 1: an in-repo link was backed up"; fi

# --- Run 2: a no-op; the pristine .bak is untouched ----------------------------
run link
[ "$(readlink "$user_link.bak")" = "$work/mine/tmux" ] || fail "run 2: the pristine .bak changed"

# --- Uninstall: the user's link comes back as the same link; nothing else left --
run uninstall
[ -L "$user_link" ] || fail "uninstall: the user's symlink was not restored as a symlink"
[ "$(readlink "$user_link")" = "$work/mine/tmux" ] || fail "uninstall: restored link has the wrong target"
if [ -e "$user_link.bak" ] || [ -L "$user_link.bak" ]; then fail "uninstall: .bak not consumed"; fi
if [ -e "$stale_link" ] || [ -L "$stale_link" ]; then fail "uninstall: the replaced in-repo link left something behind"; fi
if [ -e "$stale_link.bak" ] || [ -L "$stale_link.bak" ]; then fail "uninstall: a .bak appeared for the in-repo link"; fi
[ -d "$work/mine/tmux" ] || fail "uninstall: the user's link target was disturbed"

# --- Two checkouts, one install state ---------------------------------------------
B="$work/checkout-b"; mkdir -p "$B"
tar -C "$repo_root" --exclude=./.git -cf - . | tar -C "$B" -xf -
B="$(cd "$B" && pwd -P)"
A="$repo_root"

# consistent - the targets file holds exactly one pair per manifest entry.
consistent() {
  local st="$XDG_STATE_HOME/dotfiles"
  [ "$(cut -f1 "$st/targets" | LC_ALL=C sort)" = "$(LC_ALL=C sort -u "$st/manifest")" ] \
    || fail "$1: targets file out of step with the manifest"
}
# nobak DEST... - none of DEST has a .bak.
nobak() {
  local d
  for d in "$@"; do
    if [ -e "$d.bak" ] || [ -L "$d.bak" ]; then fail "$ctx: $d was backed up"; fi
  done
}
fresh() {
  export HOME="$work/$1"
  export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" \
         XDG_STATE_HOME="$HOME/.local/state"
  mkdir -p "$XDG_CONFIG_HOME"
}
from() { "$1/install.sh" link >"$work/from.log" 2>&1 || fail "$ctx: install.sh link from $1: $(cat "$work/from.log")"; }

fresh h2; tm="$XDG_CONFIG_HOME/tmux" nv="$XDG_CONFIG_HOME/nvim" ze="$HOME/.zshenv"
ctx="A then B"; from "$A"; from "$B"
[ "$(readlink "$tm")" = "$B/config/tmux" ] || fail "$ctx: tmux not relinked to B"
[ "$(readlink "$ze")" = "$B/zsh/zshenv" ] || fail "$ctx: .zshenv not relinked to B"
nobak "$tm" "$nv" "$ze"; consistent "$ctx"
grep -qxF -- "$(printf '%s\t%s' "$tm" "$B/config/tmux")" "$XDG_STATE_HOME/dotfiles/targets" \
  || fail "$ctx: the pair was not rewritten to B's target"
ctx="back to A"; from "$A"
[ "$(readlink "$tm")" = "$A/config/tmux" ] || fail "$ctx: tmux not relinked to A"
nobak "$tm" "$nv" "$ze"; consistent "$ctx"

# A recorded destination the user repointed: its target no longer matches the pair.
ctx="repointed"; rm -f -- "$nv"; ln -s "$work/mine/tmux" "$nv"
from "$B"
[ "$(readlink "$nv.bak")" = "$work/mine/tmux" ] || fail "$ctx: a repointed recorded destination was not backed up"
nobak "$tm" "$ze"; consistent "$ctx"

# A missing pair, the targets file present: that one link is backed up.
ctx="missing pair"; st="$XDG_STATE_HOME/dotfiles"
from "$A"
grep -vF -- "$(printf '%s\t' "$tm")" "$st/targets" > "$work/t" && cat "$work/t" > "$st/targets"
from "$B"
[ "$(readlink "$tm.bak")" = "$A/config/tmux" ] || fail "$ctx: a link with no pair was not backed up"
nobak "$ze"; consistent "$ctx"

# The targets file missing (a host installed before it existed): backed up once.
fresh h3; ctx="no targets file"; from "$A"
rm -f -- "$XDG_STATE_HOME/dotfiles/targets"
from "$B"
[ "$(readlink "$XDG_CONFIG_HOME/tmux.bak")" = "$A/config/tmux" ] || fail "$ctx: A's link was not backed up"
consistent "$ctx"

# A user symlink into A that no install recorded, seen from B: the user's.
fresh h4; ctx="unrecorded into A"
ln -s "$A/config/tmux" "$XDG_CONFIG_HOME/tmux"
from "$B"
[ "$(readlink "$XDG_CONFIG_HOME/tmux.bak")" = "$A/config/tmux" ] || fail "$ctx: an unrecorded link into A was not backed up"
consistent "$ctx"

# Uninstall from B removes the links A made (recorded pairs) and restores their
# .baks; a recorded destination the user repointed, and a link into A with no
# pair, are the user's and stay.
fresh h5; ctx="uninstall A's links from B"
tm="$XDG_CONFIG_HOME/tmux" nv="$XDG_CONFIG_HOME/nvim" ze="$HOME/.zshenv" rc="$XDG_CONFIG_HOME/zsh/.zshrc"
printf 'user tmux\n' > "$tm"
from "$A"
rm -f -- "$nv"; ln -s "$work/mine/tmux" "$nv"
grep -vF -- "$(printf '%s\t' "$rc")" "$XDG_STATE_HOME/dotfiles/targets" > "$work/t" \
  && cat "$work/t" > "$XDG_STATE_HOME/dotfiles/targets"
"$B/install.sh" uninstall >/dev/null 2>&1 || fail "$ctx: uninstall failed"
{ [ -f "$tm" ] && [ ! -L "$tm" ] && [ "$(cat "$tm")" = "user tmux" ]; } || fail "$ctx: A's tmux link not removed and its .bak restored"
if [ -e "$ze" ] || [ -L "$ze" ]; then fail "$ctx: A's recorded .zshenv link was left"; fi
[ "$(readlink "$nv")" = "$work/mine/tmux" ] || fail "$ctx: the user's repointed link was touched"
[ "$(readlink "$rc")" = "$A/zsh/zshrc" ] || fail "$ctx: a link into A with no pair was removed"

fresh h6; ctx="uninstall after A then B"
tm="$XDG_CONFIG_HOME/tmux"; printf 'user tmux\n' > "$tm"
from "$A"; from "$B"
"$B/install.sh" uninstall >/dev/null 2>&1 || fail "$ctx: uninstall failed"
{ [ -f "$tm" ] && [ "$(cat "$tm")" = "user tmux" ]; } || fail "$ctx: tmux .bak not restored"
if [ -e "$HOME/.zshenv" ] || [ -L "$HOME/.zshenv" ]; then fail "$ctx: .zshenv left behind"; fi
consistent "$ctx"

# A destination outside $HOME (XDG_CONFIG_HOME pointed elsewhere) is refused by
# link itself, so install never creates what uninstall would refuse to remove.
# The run is partial: every other link is placed, and install exits 1.
fresh h7; ctx="destination outside HOME"
export XDG_CONFIG_HOME="$work/outcfg"; mkdir -p "$XDG_CONFIG_HOME"
rc=0; "$A/install.sh" link >"$work/h7.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "$ctx: install.sh link must exit 1 (got $rc): $(cat "$work/h7.log")"
grep -qF "link: refusing $XDG_CONFIG_HOME/tmux - outside the home directory" "$work/h7.log" \
  || fail "$ctx: the refusal was not reported"
if [ -e "$XDG_CONFIG_HOME/tmux" ] || [ -L "$XDG_CONFIG_HOME/tmux" ]; then fail "$ctx: a link was created outside \$HOME"; fi
[ "$(readlink "$HOME/.zshenv")" = "$A/zsh/zshenv" ] || fail "$ctx: the links under \$HOME were not placed"
grep -qF "$XDG_CONFIG_HOME/" "$XDG_STATE_HOME/dotfiles/manifest" && fail "$ctx: an outside-HOME path was recorded"

# A real SIGTERM between the targets stage and its publish (right after the
# manifest rename, via an mv shim that signals install.sh once) leaves no staged
# targets.* file behind, and the exit trap's merge republishes the same pairs.
fresh h8; ctx="interrupted publish"
from "$A"
st="$XDG_STATE_HOME/dotfiles"; before="$(cksum < "$st/targets")"
shim="$work/mvshim"; mkdir -p "$shim"; mark="$work/mvshim.fired"
printf '#!/bin/sh\n%s "$@"; rc=$?\nfor last in "$@"; do :; done\nif [ "$last" = "%s" ] && [ ! -e "%s" ]; then : > "%s"; kill -TERM "$PPID"; fi\nexit $rc\n' \
  "$(command -v mv)" "$st/manifest" "$mark" "$mark" > "$shim/mv"
chmod u+x "$shim/mv"
rc=0; PATH="$shim:$PATH" "$A/install.sh" link >/dev/null 2>&1 || rc=$?
[ -e "$mark" ] || fail "$ctx: the signal hook never fired (test is vacuous)"
[ "$rc" -eq 143 ] || fail "$ctx: install.sh did not exit on the signal (got $rc)"
leftover="$(find "$st" -name 'targets.*' -o -name '.targets.*' -o -name '.manifest.*')"
[ -z "$leftover" ] || fail "$ctx: a staged or scratch file survived the interrupt: $leftover"
[ "$(cksum < "$st/targets")" = "$before" ] || fail "$ctx: the published targets changed"
consistent "$ctx"

# A manifest line outside $HOME (a HOME that moved, a tampered file): with
# nothing there it is dropped once, with a warning, and the next run is clean;
# with something there it stays, and the run fails with its own message.
fresh h9; ctx="stale outside-HOME line"
from "$A"
m="$XDG_STATE_HOME/dotfiles/manifest"
printf '%s\n' "$work/stale9/x" >> "$m"
from "$A"
grep -qF "prune: dropping $work/stale9/x from the manifest - outside the home directory, and nothing is there" "$work/from.log" \
  || fail "$ctx: the dropped line was not reported"
grep -qxF "$work/stale9/x" "$m" && fail "$ctx: the line with nothing on disk was kept"
from "$A"
grep -qF "outside the home directory" "$work/from.log" && fail "$ctx: the second run still warned"
mkdir -p "$work/stale9"; printf 'theirs\n' > "$work/stale9/y"
printf '%s\n' "$work/stale9/y" >> "$m"
rc=0; "$A/install.sh" link >"$work/h9.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "$ctx: a kept line must fail the run (got $rc)"
grep -qF "prune: keeping $work/stale9/y recorded - outside the home directory, and something is there" "$work/h9.log" \
  || fail "$ctx: the kept line was not reported"
grep -qF "the manifest keeps an entry the framework may not act on" "$work/h9.log" || fail "$ctx: no distinct summary"
grep -qF "could not be created" "$work/h9.log" && fail "$ctx: a kept line was reported as a link that could not be created"
grep -qxF "$work/stale9/y" "$m" || fail "$ctx: the line with something on disk was dropped"
[ "$(cat "$work/stale9/y")" = "theirs" ] || fail "$ctx: the file outside \$HOME was touched"
sed -i.x "\|^$work/stale9/y\$|d" "$m" && rm -f -- "$m.x"

# Uninstall leaves the targets file in step with the manifest (neither is removed;
# --purge removes both with the state directory).
ctx="uninstall"; "$B/install.sh" uninstall >/dev/null 2>&1 || fail "$ctx: uninstall failed"
consistent "$ctx"
"$B/install.sh" uninstall --purge >/dev/null 2>&1 || fail "$ctx: uninstall --purge failed"
[ ! -e "$XDG_STATE_HOME/dotfiles/targets" ] || fail "$ctx: --purge left the targets file"

echo "PASS: link_symlink_backup_test"
