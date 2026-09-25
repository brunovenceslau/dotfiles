#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# install.sh - link the dotfiles into $HOME by convention.
#
#   install.sh [install]   create state/cache dirs, then (re)create every link
#   install.sh link        (re)create only the links + manifest
#
# The link engine, exceptions table and uninstall manifest live in lib/link.sh.
# `make smoke` (bin/smoke) proves this installer's idempotency end-to-end on
# both target platforms, macOS arm64 and macOS Intel. Package installation and
# its guard (Homebrew instruct-and-stop) live with the package-install step in
# lib/packages.sh - without a package step there is nothing to stop on, so the
# guard is implemented where it is actually testable.
#
# Bash 3.2 compatible (no associative arrays, no mapfile,
#   no ${var,,}) - the macOS system /bin/bash is 3.2.
# Idempotent - a re-run is a no-op (no new .bak, identical links,
#   byte-stable manifest); the smoke gate asserts this via its re-run diff.
set -euo pipefail

log()  { printf '%s\n' "install: $*"; }
warn() { printf '%s\n' "install: $*" >&2; }

# Self-resolving repo root: resolve this script's own path (BASH_SOURCE, not $0,
# so resolution is correct even when the file is SOURCED - e.g. a test calling a
# helper), to the directory holding it, so `./install.sh` works from any cwd.
# pwd -P canonicalizes symlinked path components; it does not resolve a symlink to
# the script file itself, which the clone-and-run flow never needs. install-time
# only - no-fork rule governs the startup path, not the installer.
DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# os.sh no longer gates anything here - it is sourced for the arch helpers, which
# a host's own additions may call.
# shellcheck source=lib/os.sh
. "$DOTFILES/lib/os.sh"
# shellcheck source=lib/link.sh
. "$DOTFILES/lib/link.sh"
# shellcheck source=lib/uninstall.sh
. "$DOTFILES/lib/uninstall.sh"
# shellcheck source=lib/packages.sh
. "$DOTFILES/lib/packages.sh"

# XDG targets - honor a pre-set value, otherwise the spec default (must match
# zsh/zshenv, which exports the same fallbacks).
xdg_config="${XDG_CONFIG_HOME:-$HOME/.config}"
xdg_cache="${XDG_CACHE_HOME:-$HOME/.cache}"
xdg_state="${XDG_STATE_HOME:-$HOME/.local/state}"
zdotdir="$xdg_config/zsh"
manifest_dir="$xdg_state/dotfiles"
manifest="$manifest_dir/manifest"

# vgit - git in the repo with ALL ambient config-injection channels neutralized:
# the GLOBAL/SYSTEM files AND the GIT_CONFIG_COUNT/KEY_*/VALUE_* + GIT_CONFIG_
# PARAMETERS + GIT_CONFIG env families. Every fetch and merge on the upgrade path
# runs through this, so no user, machine or .local git config can rewrite the
# fetch URL: a hostile url.insteadOf in ~/.gitconfig would otherwise redirect the
# unpinned `git fetch origin` to another repository.
# Repo-local .git/config still applies: an attacker who can write it already owns
# the working tree, so it is out of scope by the same logic as install.sh itself
# (PATH likewise - it already owns `git`).
# Scrubbing also drops the tracked config's fsckObjects, so re-assert them here
# with -c: the upgrade never fetches under a config with object fsck off. Object
# fsck happens at the fetch's index-pack; the ff-only merge only touches objects
# already fsck'd on the way in. Injecting via the wrapper also extends fsck to the
# submodule fetch (the SHA-pinned plugin objects). The flags are harmless on
# non-fetch vgit calls (rev-parse etc. ignore them); receive.fsckObjects is inert
# on a client fetch but kept as defense-in-depth.
# GNUPGHOME=/dev/null is no-trace defense-in-depth: today no vgit call probes gpg
# (fetch / merge --ff-only / rev-parse do not), so it changes nothing - but if the
# upgrade path ever grows a gpg-probing git call (log --show-signature), this keeps
# vgit from materializing a ~/.gnupg in a scratch HOME.
vgit() {
  env -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT -u GIT_CONFIG \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GNUPGHOME=/dev/null \
    git -c transfer.fsckObjects=true -c fetch.fsckObjects=true -c receive.fsckObjects=true \
    -C "$DOTFILES" "$@"
}

# The manifest is the sole uninstall source of truth, so every
# on-disk framework link MUST be recorded even when a run ends abnormally. A
# refused link no longer aborts do_link (it continues and finalizes), so on any
# normal completion the manifest is already the complete set and the scratch is
# gone - this trap then no-ops. The remaining abnormal case is a SIGNAL (Ctrl-C /
# SIGTERM) interrupting do_link before finalize: UNION whatever links were already
# created into the existing manifest (a superset never orphans a link), then drop
# the scratch so the state dir keeps only the manifest.
LINK_MANIFEST=""
UPGRADE_LOCK=""
_install_cleanup() {
  # Release a held upgrade lock (a mkdir dir) so an interrupted upgrade never
  # leaves a stale lock the user must remove by hand. Best-effort, before the
  # manifest merge so a failure of either still runs the other.
  if [ -n "$UPGRADE_LOCK" ]; then rmdir "$UPGRADE_LOCK" 2>/dev/null || :; fi
  [ -n "$LINK_MANIFEST" ] || return 0
  # Best-effort: never let cleanup itself abort the trap under set -e.
  link_manifest_merge "$manifest" || :
  rm -f -- "$LINK_MANIFEST"
}
trap _install_cleanup EXIT
# Route INT/TERM through EXIT so the cleanup (lock release, manifest merge) actually
# runs on a Ctrl-C / kill - an untrapped fatal signal skips the EXIT trap and would
# orphan the lock (and, per the comment above, the in-flight manifest scratch).
trap 'exit 130' INT
trap 'exit 143' TERM

# do_link - (re)create every framework link and rewrite the uninstall manifest.
# `install.sh link` runs exactly this and nothing else.
# Core + conventional links are all recorded, so the manifest is
#   the complete, sole source of truth for uninstall. Links are collected into a
#   mktemp scratch file (unpredictable name - no symlink-follow), then finalized
#   (sorted, deduped) into $manifest atomically. Every link is attempted even if
#   one is refused (`|| rc=1`), so a single conflict never blocks the rest and the
#   manifest still records every link actually placed; do_link then returns
#   non-zero so the caller can fail loudly.
do_link() {
  mkdir -p "$manifest_dir"
  LINK_MANIFEST="$(mktemp "$manifest_dir/.manifest.XXXXXX")"
  local rc=0

  # ~/.zshenv is the only framework-managed file in $HOME; it
  # exports ZDOTDIR so the interactive config lives under $ZDOTDIR (XDG).
  link "$DOTFILES/zsh/zshenv" "$HOME/.zshenv" || rc=1
  link "$DOTFILES/zsh/zshrc"  "$zdotdir/.zshrc" || rc=1
  # Surface the .zshrc.local TEMPLATE beside where the user creates
  # .zshrc.local (the packages/*.local.example are read in place, so need no link).
  # Best-effort - a per-file `[ -e ] && link`, NOT link_tree,
  # which symlinks WHOLE config/ dirs, so their .example files ride inside the dir link, never
  # individually. A clone WITHOUT the template (a stripped subset, a minimal test fixture)
  # must not fail the install - it is an onboarding aid, not essential config. A real clone
  # always carries it, so it is linked there.
  [ -e "$DOTFILES/zsh/.zshrc.local.example" ] && \
    { link "$DOTFILES/zsh/.zshrc.local.example" "$zdotdir/.zshrc.local.example" || rc=1; }

  # The convention set + exceptions table.
  link_tree "$DOTFILES" || rc=1

  # Reclaim on-disk orphans - links a prior manifest recorded that
  # this run no longer produces (still symlinks into the repo). $DOTFILES is the
  # containment predicate; without it finalize prunes nothing.
  # GATED ON A CLEAN RUN: prune ONLY when every link was produced (rc == 0). On a
  # partial run (a source momentarily missing, a refused link), a still-wanted link
  # can be absent from this run's set for reasons other than "its rule was removed";
  # pruning then would unlink a live config.
  # A partial run UNIONs instead of replacing (link_manifest_merge, the same
  # superset the abort path uses): it must not prune, and it must NOT drop a prior
  # entry either - replacing would strand a rule-removal-during-a-partial-run orphan
  # OFF the manifest, so no later clean run could ever reclaim it. Union keeps every
  # prior entry so the next clean run reclaims what is genuinely gone.
  if [ "$rc" -eq 0 ]; then
    link_manifest_finalize "$manifest" "$DOTFILES"
  else
    link_manifest_merge "$manifest"
  fi
  rm -f -- "$LINK_MANIFEST"
  return "$rc"
}

# _migrate_legacy_history - carry a pre-XDG ~/.zsh_history into the framework's
# $XDG_STATE_HOME/zsh/history on a FIRST install. Copy, never move: the old file
# stays where it is, so a rollback to the old setup still has its history.
# Skipped entirely once the destination exists, so it can never overwrite live
# history - including on every re-run, which keeps `install.sh` idempotent.
_migrate_legacy_history() {
  local legacy="$HOME/.zsh_history" dest="$xdg_state/zsh/history"
  [ -s "$legacy" ] || return 0
  [ -e "$dest" ] && return 0
  mkdir -p "$xdg_state/zsh" || return 0
  # umask 077 in a subshell: cp creates the file under the ambient umask
  # (typically 644) BEFORE any chmod could tighten it, and shell history often
  # holds secrets typed on a command line. The chmod stays as belt-and-braces for
  # a destination that somehow already existed with looser bits.
  if ! ( umask 077 && cp -- "$legacy" "$dest" ); then
    warn "could not copy ~/.zsh_history to $dest - starting with an empty history"
    return 0
  fi
  chmod 600 "$dest" 2>/dev/null \
    || warn "copied ~/.zsh_history to $dest but could not chmod it 600 - check its permissions"
  log "carried ~/.zsh_history over to ${dest#"$HOME"/} (the original is untouched)"
}

# _cache_shell_inits - pre-compile the zsh integration the startup path sources:
# `<tool> init zsh` for starship and zoxide, `canga completion zsh` for canga.
# The startup path takes no subprocess (bin/startup-fork-gate proves it), and
# these tools ship their integration as a command to eval - so the fork happens
# HERE, once per install/upgrade, instead of once per shell.
#
# canga's script is cobra's DYNAMIC completion: it asks `canga __complete` on
# every TAB, so the subcommands a `canga upgrade` adds are offered without
# regenerating this cache. Only a change to cobra's script format would need a
# refresh, and the next link/upgrade provides it.
#
# Best-effort by design: a missing tool leaves no cache and zshrc's `[ -r ]` guard
# then skips it silently. Written via a temp + mv so a half-written cache is never
# sourced. The cache lives under $XDG_CACHE_HOME/zsh - these ARE zsh scripts, and
# that is a directory `dotfiles-uninstall --purge` already sweeps, so the
# no-trace audit keeps holding without teaching uninstall a new path.
_cache_shell_inits() {
  local cache_dir="$xdg_cache/zsh" tool bin out tmp
  mkdir -p "$cache_dir" || { warn "could not create $cache_dir - shell integrations will be skipped"; return 0; }
  # canga replaced devctl, the completion this framework integrated with before
  # it, and nothing sources devctl's cache any more. Removed on every run (a
  # no-op once it is gone), or the orphan outlives the replacement.
  rm -f -- "$cache_dir/devctl-completion.zsh"
  for tool in starship zoxide canga; do
    # A case, not a lookup table: bash 3.2 has no associative arrays. `set --`
    # carries the generator's argv, so the call below stays one quoted "$@".
    case "$tool" in
      # canga is OPTIONAL, like starship and zoxide, and is not installed by
      # this framework: https://github.com/brunovenceslau/canga
      canga) out="$cache_dir/canga-completion.zsh"; set -- completion zsh ;;
      *)     out="$cache_dir/$tool-init.zsh";       set -- init zsh ;;
    esac
    # Resolve against the PATH the SHELL will have, not the installer's own:
    # zshrc prepends ~/.local/bin, where canga installs, but a bash, a script or
    # a first install from a fresh terminal does not carry it. Without the prefix
    # such a run would call a working cache "stale" and delete it.
    if ! bin="$(PATH="$HOME/.local/bin:$PATH" command -v "$tool" 2>/dev/null)"; then
      # Stale cache from a tool that has since been uninstalled would keep
      # configuring a shell for a binary that is gone.
      [ -e "$out" ] && { rm -f -- "$out"; log "removed the stale $tool shell integration (binary is gone)"; }
      continue
    fi
    tmp="$(mktemp "$out.XXXXXX")" || { warn "$tool: mktemp failed - skipping its shell integration"; continue; }
    # STARSHIP_CACHE MUST match zsh/zshenv's export. This runs from bash, which
    # never reads zshenv, and starship creates its log dir on every call - without
    # it, `starship init` writes ~/.cache/starship, outside the tree --purge sweeps.
    # A prefix assignment scopes it to this one call; zoxide and canga ignore it.
    if STARSHIP_CACHE="$cache_dir/starship" "$bin" "$@" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      mv -f -- "$tmp" "$out"
      log "cached the $tool shell integration"
    else
      rm -f -- "$tmp"
      warn "$tool $* produced nothing - its shell integration is skipped"
    fi
  done
}

# ensure_submodules - a non-recursive `git clone` (one without
# --recurse-submodules) leaves zsh/plugins/* empty, and the static loader
# then silently degrades to no plugins. Heal that at install time (
# the SHA-pinned zsh plugins must actually be present). Guarded to run ONLY
# when a submodule is missing - `git submodule status` prefixes an uninitialized
# one with '-', so a healthy checkout (a recursive clone, or the host's own dev
# tree) is a strict no-op and a locally bumped pin ('+' prefix) is never disturbed.
# The pins in .gitmodules/index decide the commit; this only materializes them.
# Object fsck is forced ON with -c, exactly as vgit does on the upgrade path: the
# tracked config's fsckObjects only applies when the linked XDG git config
# includes it, which a pre-existing real ~/.config/git/config never does, and an
# ambient config could turn it off. -c beats every config file and reaches the
# submodule clones through GIT_CONFIG_PARAMETERS.
ensure_submodules() {
  command -v git >/dev/null 2>&1 || return 0
  [ -f "$DOTFILES/.gitmodules" ] || return 0
  # A here-string, not `git ... | grep -q`: under pipefail, grep -q exiting on
  # the first `-` line can SIGPIPE git mid-output, and the failed pipeline would
  # read as "nothing missing" and skip the init.
  grep -q '^-' <<<"$(git -C "$DOTFILES" submodule status 2>/dev/null)" || return 0
  log "initializing SHA-pinned plugin submodules (a non-recursive clone left them empty)"
  git -C "$DOTFILES" -c fetch.fsckObjects=true -c transfer.fsckObjects=true \
    submodule update --init \
    || warn "submodule init failed; plugins may be absent - run: git -C \"$DOTFILES\" -c fetch.fsckObjects=true -c transfer.fsckObjects=true submodule update --init --recursive"
}

# harden_plugin_perms - strip group/other write from the plugin tree, the only
# framework-owned directories on the shell's fpath (zsh-completions/src and its
# parent). compinit's audit (compaudit) inspects every fpath dir and its parent:
# a group- or world-writable one makes it fork `getent group` on the startup
# path, and on a shared group (macOS `staff`) it also reports the dirs as
# insecure and asks whether to use them. A clone made under umask 002, or a
# submodule checkout that ran under it, leaves exactly that. git records no
# directory modes and only the owner-execute bit of files, so this never dirties
# the tree. Runs after every submodule materialization: `install` (after
# ensure_submodules) and `link` (which the upgrade re-enters after its
# submodule update). Best-effort: a path the user does not own is left as is.
harden_plugin_perms() {
  local plugins="$DOTFILES/zsh/plugins"
  [ -d "$plugins" ] || return 0
  chmod -R go-w -- "$plugins" 2>/dev/null \
    || warn "could not remove group/other write from $plugins - compinit may flag it as insecure"
  return 0
}

# do_uninstall [--purge] - reverse the install from the manifest.
# Remove only manifest-listed links + restore *.bak; --purge also
# clears generated state/cache. Continue-and-report like do_link: attempt every
# removal, return non-zero if any failed.
do_uninstall() {
  local purge=0 rc=0 owner
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge) purge=1 ;;
      *) warn "uninstall: unknown option: $1 (expected: --purge)"; return 2 ;;
    esac
    shift
  done
  # Privilege boundary: a user-writable manifest must never drive root-privileged
  # rm/mv (e.g. a reflexive `sudo -E ./install.sh uninstall`). A root-owned
  # manifest is fine - that is the CI container, where root created the scratch
  # HOME. stat -c is GNU, -f is BSD; an unreadable owner fails closed.
  if [ "$(id -u)" -eq 0 ] && [ -f "$manifest" ]; then
    owner="$(stat -c %u "$manifest" 2>/dev/null || stat -f %u "$manifest" 2>/dev/null)"
    if [ "$owner" != "0" ]; then
      warn "uninstall: refusing to run as root over a manifest owned by uid ${owner:-unknown}"
      warn "           run as the owning user instead (sudo is never needed here)"
      return 1
    fi
  fi
  uninstall_links "$manifest" || rc=1
  if [ "$purge" -eq 1 ]; then
    uninstall_purge || rc=1
  fi
  return "$rc"
}

# do_upgrade - single-flight wrapper: take a mkdir lock under the state dir so
# two concurrent upgrades cannot interleave fetch and merge, run the real
# work, then release the lock regardless of how it returned.
do_upgrade() {
  local lock="$manifest_dir/upgrade.lock" rc
  mkdir -p "$manifest_dir"
  if ! mkdir "$lock" 2>/dev/null; then
    warn "upgrade: another upgrade appears to be in progress"
    warn "  lock DIR: $lock"
    warn "  if no upgrade is running, remove it (it is a directory):  rmdir '$lock'"
    return 1
  fi
  # Publish the lock path so the EXIT/INT/TERM trap (_install_cleanup) releases it
  # even on a Ctrl-C mid-fetch - otherwise the lock dir is orphaned.
  UPGRADE_LOCK="$lock"
  _do_upgrade; rc=$?
  rmdir "$lock" 2>/dev/null || :
  UPGRADE_LOCK=""
  return "$rc"
}

# _upgrade_apply - the convergence steps of (submodules -> link ->
# settings re-seed -> recompile), factored into ONE function called from BOTH the
# merge path and the up-to-date path so the two can never drift apart.
#
# Every tree-touching step here is a FRESH `install.sh` subcommand,
# never an in-process call. install.sh sources lib/ at start-up and git swaps a
# modified file by unlink+create, so after the merge THIS process still holds the
# PRE-merge engine while $DOTFILES holds the post-merge tree: an in-process relink
# applies the OLD link rules to the NEW config, silently, with every gate green.
# That is the pre-merge-engine defect: the pre-merge engine applied the OLD
# exceptions table to a config/ tree whose rules had changed. A child re-reads
# the merged tree from disk.
#
# The child runs POST-MERGE code - but so does the merged zshrc at the next shell,
# so the delta is timing, not reachability. What IS guaranteed by construction is its SCOPE: it
# recomputes DOTFILES from its own BASH_SOURCE, reads HOME/XDG_* from the inherited
# environment, enters only the named subcommand's arm, never re-enters do_upgrade,
# and never touches the upgrade lock (UPGRADE_LOCK is a plain shell variable,
# unexported, so the child's EXIT trap cannot release the parent's lock). Only
# `link` is sanctioned here; `install` would re-run the
# whole first-install path, which an upgrade must never do.
# "${BASH:-bash}" is this same interpreter, already absolute.
#
# The up-to-date path calls this too. An upgrade interrupted after
# its merge leaves the installed state behind the tree, and re-running
# dotfiles-upgrade is the user's recovery path - so "nothing to merge" must still
# converge instead of returning success without doing anything, which is what made
# the pre-merge-engine defect permanent rather than merely a one-cycle lag.
_upgrade_apply() {
  local rc=0
  # >>> POST-MERGE BOUNDARY
  vgit submodule update --init || { warn "upgrade: submodule update failed"; rc=1; }
  "${BASH:-bash}" "$DOTFILES/install.sh" link \
    || { warn "upgrade: relink reported problems"; rc=1; }
  if command -v zsh >/dev/null 2>&1; then
    DOTS="$DOTFILES" zsh -f -c '
      for f in "$DOTS"/zsh/plugins/*/*.zsh(N) "$DOTS"/zsh/plugins/*/*.plugin.zsh(N); do
        [[ -s $f.zwc && $f.zwc -nt $f ]] || zcompile -R -- "$f.zwc" "$f" 2>/dev/null
      done' 2>/dev/null || :
  fi
  # <<< POST-MERGE BOUNDARY END
  return "$rc"
}

# _do_upgrade - fetch, fast-forward the repo, then re-link and recompile. The
# merge is --ff-only, which is the anti-rollback gate: a diverged or rewound
# history is refused rather than reset to. Any failure leaves HEAD, the working
# tree and submodules exactly as they were.
_do_upgrade() {
  local rc=""

  # A dirty tracked tree cannot be fast-forwarded cleanly; refuse before touching
  # anything. `.local` files are untracked and invisible to this check.
  if [ -n "$(vgit status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    warn "upgrade: tracked files have local modifications - commit or stash first"
    return 1
  fi

  log "upgrade: fetching origin"
  # fsckObjects is injected by the vgit wrapper, so the fetch that
  # ingests untrusted objects is already object-fsck'd - no inline -c needed here.
  #
  # AUTH re-inject: vgit scrubs the global config to kill a hostile
  # url.insteadOf / gpg.ssh.program - which ALSO drops the credential helper the
  # operator configured for an HTTPS remote, so the upgrade fetch would prompt
  # `Username for github.com` on the startup-adjacent path. Re-inject ONLY
  # credential.helper (resolved for THIS remote from the trusted local/global config)
  # and run non-interactively: GIT_TERMINAL_PROMPT=0 makes a missing/failing
  # credential fail LOUDLY instead of hanging on a prompt. This authenticates the
  # fetch of the FIXED remote URL - it neither rewrites the remote (url.insteadOf
  # stays scrubbed in vgit).
  #
  # The helper READ MUST use the same env discipline as vgit, or it re-opens the
  # very config-injection channel vgit closes: a `credential.helper` beginning with
  # `!` is an arbitrary command git runs during auth.
  # So scrub the ambient config-injection env families and PIN GIT_CONFIG_GLOBAL to
  # the known XDG config (its `[include] config.local` is still processed, so a real
  # helper is honored) - a poisoned GIT_CONFIG_PARAMETERS / GIT_CONFIG_GLOBAL env can
  # no longer supply the helper. `config --get remote.origin.url` reads the RAW url
  # (immune to url.insteadOf, unlike `remote get-url`), so remote_url is unsteerable.
  local remote_url cred_all cred_helper h
  remote_url="$(git -C "$DOTFILES" config --get remote.origin.url 2>/dev/null || true)"
  cred_all="$(env -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT -u GIT_CONFIG \
    GIT_CONFIG_GLOBAL="$xdg_config/git/config" GIT_CONFIG_SYSTEM=/dev/null \
    git -C "$DOTFILES" config --get-urlmatch credential.helper "$remote_url" 2>/dev/null || true)"
  cred_helper=""
  while IFS= read -r h; do
    [ -n "$h" ] && { cred_helper="$h"; break; }   # first non-empty (gh writes an empty reset first)
  done <<EOF
$cred_all
EOF
  if ! GIT_TERMINAL_PROMPT=0 vgit -c credential.helper="$cred_helper" fetch origin; then
    warn "upgrade: fetch failed"
    warn "  Network unreachable? Check that first: the public HTTPS remote needs"
    warn "  no credentials to fetch."
    warn "  Credentials needed (a private fork, or an SSH remote)? The upgrade"
    warn "  fetch scrubs ~/.gitconfig and reads only the XDG config, so put a"
    warn "  credential helper there:"
    warn "    git config -f ~/.config/git/config.local 'credential.https://github.com.helper' '!gh auth git-credential'"
    return 1
  fi
  if [ "$(vgit rev-parse FETCH_HEAD)" = "$(vgit rev-parse HEAD)" ]; then
    # A fresh fetch just confirmed there is nothing to pull - clear any stale
    # "available" sentinel a past cadence check left, so the precmd notice
    # stops nagging once we are already current.
    rm -f "$xdg_state/dotfiles/update-available"
    log "upgrade: already up to date"
    # Nothing to merge is NOT nothing to do - reconcile the installed
    # state against the current tree. Returning here unconditionally is what made
    # the pre-merge-engine defect survive: the user's natural recovery (re-run dotfiles-upgrade) reported
    # success forever while the links stayed wrong.
    _upgrade_apply || { warn "upgrade: reconciliation reported problems"; return 1; }
    return 0
  fi

  # ff-only merge (anti-rollback: non-descendant/rewound history is refused,
  # never reset to) -> submodules -> relink -> recompile stale byte-code.
  vgit merge --ff-only FETCH_HEAD \
    || { warn "upgrade: fast-forward merge refused (diverged or rewound history)"; return 1; }
  # >>> POST-MERGE BOUNDARY
  # $DOTFILES is now AHEAD of the lib/ code this process sourced, so below this
  # line nothing may reach the in-process link engine - every tree-touching step
  # goes through _upgrade_apply's fresh `install.sh` subcommands, which run the
  # MERGED code. The sentinels are a REVIEW MARKER, not an enforced gate; the
  # behavioural proof is tests/upgrade_test.sh cases 1/2/22/24.
  _upgrade_apply || rc=1

  # The merge applied, so the update-check notice is stale - clear
  # it now rather than let it linger up to a cadence window. The next background
  # fetch would also clear it, but a just-upgraded shell should not still nag.
  rm -f "$xdg_state/dotfiles/update-available"
  log "upgrade: done - HEAD is now $(vgit rev-parse --short HEAD)"
  # <<< POST-MERGE BOUNDARY END
  return "${rc:-0}"
}

# authoring-side advisory. The tracked git config deliberately omits
# commit.gpgsign (a keyless fresh clone must still be able to commit), so a host
# with no config.local commits UNSIGNED with no other signal - and nothing catches
# that until another machine's post-cutover upgrade REFUSES those commits. Warn once
# at install time, pointing at the example. Non-fatal; reads the global config
# (the linked ~/.config/git/config + its config.local include).
_signing_advisory() {
  command -v git >/dev/null 2>&1 || return 0
  # Read the EFFECTIVE commit.gpgsign as a real commit would - ALL levels combined
  # (system + XDG global + ~/.gitconfig) - from a non-repo cwd ($HOME) so the
  # dotfiles repo's own local config can't skew it. NOT --global: that selects a
  # SINGLE global file (~/.gitconfig when it exists) and ignores the framework's
  # XDG config where config.local lives - so a --global read would false-fire when
  # a residual ~/.gitconfig sits alongside a signing-enabled config.local. Includes
  # are on by default without --global; --type=bool normalizes yes/on/1/True.
  if [ "$(git -C "$HOME" config --includes --type=bool --get commit.gpgsign 2>/dev/null)" != true ]; then
    warn "commit signing is NOT enabled on this host (commit.gpgsign is unset)."
    warn "  set user.signingkey + commit.gpgsign in ~/.config/git/config.local"
    warn "  (see config/git/config.local.example). Optional: nothing refuses an"
    warn "  unsigned commit, but GitHub will not show the Verified badge."
    return 0
  fi
  # Signing is on - but a residual ~/.gitconfig can override the framework's XDG
  # config: e.g. a legacy GPG signingkey against the framework's gpg.format=ssh
  # makes every commit FAIL CLOSED, while commit.gpgsign still reads true. The
  # framework is XDG-only; warn if a home-dir gitconfig carries signing settings.
  if [ -f "$HOME/.gitconfig" ] \
     && git config --file "$HOME/.gitconfig" --get-regexp '^(user\.signingkey|gpg\.|commit\.gpgsign)' >/dev/null 2>&1; then
    warn "a legacy ~/.gitconfig carries signing settings and may override the"
    warn "  framework's XDG config (e.g. a GPG signingkey vs gpg.format=ssh),"
    warn "  which can make commits fail. Migrate host-specific settings into"
    warn "  ~/.config/git/config.local and remove ~/.gitconfig (XDG-only model)."
    warn "  To STAY on GPG during the interim, set gpg.format=openpgp in config.local."
  fi
}

# Dispatch only when executed, not when sourced - so tests (and any future tool)
# can source this file to call helpers like _signing_advisory in isolation without
# triggering an install. Guard, not re-indented, to keep the case readable.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
cmd="${1:-install}"
case "$cmd" in
  link)
    # Relink only - the relink step that dotfiles-upgrade performs.
    # Reject arguments, like `upgrade` and `reseed-settings` do: a subcommand invoked
    # across releases should fail loudly on a form it does not
    # understand rather than silently discard it.
    shift
    [ $# -eq 0 ] || { warn "link takes no arguments (got: $*)"; exit 2; }
    link_rc=0
    do_link || link_rc=1
    # After the links, so `starship` resolves its config through the freshly linked
    # ~/.config/starship. `link` is the arm the upgrade re-enters in a fresh process,
    # so caching here is what keeps the init current across a tool version bump.
    # It runs even when a link was refused, for the reason the install arm gives.
    _cache_shell_inits
    harden_plugin_perms
    [ "$link_rc" -eq 0 ] || { warn "one or more links could not be created (see warnings above)"; exit 1; }
    log "links (re)created."
    ;;
  reseed-settings)
    # RETIRED, and deliberately still here: this subcommand's NAME is a cross-version
    # ABI. The PREVIOUS release's installer invokes it on the NEW tree, so deleting the
    # arm would send that installer to the `*)` branch - exit 2, which _upgrade_apply
    # reports as a failed upgrade. It re-seeded the agent settings.json; there is no
    # longer a config surface that needs it, so it succeeds doing nothing.
    shift
    [ $# -eq 0 ] || { warn "reseed-settings takes no arguments (got: $*)"; exit 2; }
    ;;
  install)
    # Reject arguments like the other arms: `install.sh` alone means install, so
    # drop the subcommand only when it was given, then nothing may remain.
    [ $# -eq 0 ] || shift
    [ $# -eq 0 ] || { warn "install takes no arguments (got: $*)"; exit 2; }
    # State/cache dirs the startup path expects to exist, created here so zshrc
    # need not fork mkdir on a normal launch.
    mkdir -p "$xdg_state/zsh" "$xdg_cache/zsh" "$manifest_dir"
    # Before the first interactive shell writes anything, and a no-op afterwards.
    _migrate_legacy_history
    # A refused link (typically a pre-existing real ~/.config/<prog> directory)
    # still fails the install, but only AFTER the local steps below, which do not
    # depend on the refused link: skipping them left a first-time user with no
    # prompt until the conflict was fixed.
    link_rc=0
    do_link || link_rc=1
    # Materialize the SHA-pinned plugin submodules if a non-recursive clone left
    # them empty. link-only stays pure. Skipped after a refused link: that run
    # already ends in exit 1 and a re-run the user has to make, and the re-run
    # heals the submodules; fetching third-party code during a run that is
    # failing adds a network step (and its own failure modes) to a problem that
    # is purely local. Object fsck is not the reason - ensure_submodules forces
    # it itself.
    if [ "$link_rc" -eq 0 ]; then
      ensure_submodules
    else
      warn "skipping plugin submodule init because a link was refused - re-run ./install.sh once it is fixed"
    fi
    harden_plugin_perms
    # Pre-compile the shell integrations the startup path sources (starship, zoxide,
    # canga's completion) so `zsh -i` never forks to build one.
    _cache_shell_inits
    _signing_advisory   # warn if commit signing isn't set up yet
    if [ "$link_rc" -ne 0 ]; then
      warn "one or more links could not be created (see warnings above)"
      warn "  fix each refused path, then re-run ./install.sh"
      exit 1
    fi
    log "done - start a new zsh (e.g. \`exec zsh\`) to load the config."
    ;;
  upgrade)
    # Fetch -> ff-only merge -> submodules -> link -> recompile.
    # `dotfiles-upgrade` wraps this. No bypass flag by design - so reject any
    # argument rather than silently ignore a typo like `--dry-run`/`--force`.
    shift
    [ $# -eq 0 ] || { warn "upgrade takes no arguments (got: $*) - there is no bypass flag by design"; exit 2; }
    do_upgrade || { warn "upgrade did not complete (see warnings above)"; exit 1; }
    ;;
  packages)
    # Install from the tracked manifests (+ untracked .local).
    # A separate subcommand - the default `install` links only, so `make smoke`
    # never triggers a package install (which needs the network). No sudo is
    # involved on that path either: Homebrew is user-scoped.
    shift
    [ $# -eq 0 ] || { warn "packages takes no arguments (got: $*)"; exit 2; }
    packages_install || { warn "packages: installation reported problems (see warnings above)"; exit 1; }
    log "packages: done."
    ;;
  uninstall)
    # Remove framework links (+ generated state/cache with
    # --purge). `dotfiles-uninstall` wraps this. Drop the subcommand; the rest
    # are flags for do_uninstall.
    shift
    # Preserve do_uninstall's exit code: 2 for a usage error (unknown option,
    # refused before any removal), 1 for a removal that could not complete.
    do_uninstall "$@" || { rc=$?; warn "uninstall reported problems (see warnings above)"; exit "$rc"; }
    log "uninstalled - framework links removed."
    ;;
  -h | --help | help)
    printf '%s\n' "usage: install.sh [install|link|packages|upgrade|uninstall [--purge]]"
    printf '%s\n' "       (retired, kept for cross-version compatibility: reseed-settings)"
    ;;
  *)
    warn "unknown command: $cmd (expected: install | link | packages | upgrade | uninstall | reseed-settings)"
    exit 2
    ;;
esac
fi
