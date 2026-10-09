#!/bin/bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# install.sh - link the dotfiles into $HOME by convention.
#
# Each usage line below is `install.sh <name>`, then a run of 2+ spaces, then
#   its description - that gap is load-bearing: tests/subcommand_docs_test.sh
#   parses it to find where each subcommand's name ends.
#
#   install.sh [install]             create state/cache dirs, then (re)create every link
#   install.sh link                  (re)create only the links + manifest
#   install.sh packages              install from the tracked package manifests
#   install.sh upgrade               fetch, fast-forward, update submodules, relink,
#                                    recompile (wrapped by dotfiles-upgrade)
#   install.sh uninstall [--purge]   remove framework links; --purge also clears
#                                    generated cache/state (wrapped by dotfiles-uninstall)
#   install.sh identity [--name NAME] [--rotate]  derive git identity + SSH
#                                    signing from the host's allowed_signers and
#                                    ssh-agent (install runs it too); --rotate
#                                    replaces a signing key that no longer verifies
#   install.sh doctor [--verbose]    read only: print each identity, signing,
#                                    plugin submodule, Homebrew, gh or
#                                    credential helper problem in one line
#                                    (--verbose: every check)
#   install.sh -h | --help | help    print a short usage line
#
# reseed-settings is retired: kept as a no-op, cross-version ABI only (see
# "Treat an install.sh subcommand name as an ABI" in .claude/rules/shell-bash.md).
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

# Root is refused, always, for every subcommand (help and the no-op arms too:
# one rule with no exception is the one that cannot drift). This is the first
# thing the script runs, before any lib/ is sourced or any variable of its own
# is read, so nothing a user controls reaches a root process through it: not the
# checkout's code, not the state files, not a tool on the user's PATH. Bash
# itself reads BASH_ENV, SHELLOPTS and BASHOPTS before line 1; sudo's default
# env_delete strips them. The uid comes from the absolute /usr/bin/id, never
# from PATH, where a user's fake `id` would answer, and never from $EUID/$UID,
# which the environment can set. There is no override. Missing (NixOS has no
# /usr/bin/id) or unreadable, it fails closed. The shebang is the absolute
# /bin/bash for the same reason: `env bash` would run whatever bash comes first
# on PATH before this line could refuse. It runs when the file is sourced too,
# so every process holding these functions has passed it, and no function
# below asks again.
# A plain assignment, never read from the environment: the one seam a test
# overrides, inside a subshell that sourced this file.
_install_id_bin=/usr/bin/id
_install_uid() { "$_install_id_bin" -u; }
_install_refuse_root() {
  local uid
  if [ ! -x "$_install_id_bin" ]; then
    printf '%s\n' "install: cannot tell who is running this ($_install_id_bin is missing) - refusing to run" >&2
    return 1
  fi
  uid="$(_install_uid 2>/dev/null)" || uid=""
  case "$uid" in
    "" | *[!0-9]*)
      printf '%s\n' "install: cannot tell who is running this ($_install_id_bin gave no uid) - refusing to run" >&2
      return 1
      ;;
  esac
  # A numeric compare, so "00" is root too.
  if [ "$uid" -eq 0 ]; then
    printf '%s\n' "install: refusing to run as root - run it as the owning user; sudo is never needed here" >&2
    return 1
  fi
  return 0
}
_install_refuse_root || exit 1

log()  { printf '%s\n' "install: $*"; }
warn() { printf '%s\n' "install: $*" >&2; }

# _shell_word VALUE... - print each VALUE as one shell word, space-separated:
# a path in a command a message tells the operator to run, so pasting it runs
# on that path and nothing else, or an operand that came from the command
# line or the file system, shown with its word boundaries kept. The
# counterpart of lib/host_identity.py's shell_word(). A value of only
# [A-Za-z0-9@%+=:,./_-] stays bare, as shlex.quote() leaves it, so the usual
# message keeps its shape; another printable-ASCII value goes in '...', each '
# as '\''; any other value goes in $'...' (bash 3.2, bash 5 and zsh all read
# it), \ as \\, ' as \' and every byte outside printable ASCII as \xNN, so the
# word round-trips and no raw control byte reaches the terminal. Not
# printf %q, whose spelling changes with the bash version and the locale.
# Byte-wise on purpose: bash 3.2 cannot tell a printable non-ASCII character,
# so every such byte is spelled out. A subshell, so LC_ALL=C (byte-wise
# ${s:i:1} and "'c") does not leak; MUST mask with 255, because bash 3.2
# reads "'c" of a byte above 0x7f as a negative signed char.
_shell_word() (
  LC_ALL=C
  sep=""
  for s in "$@"; do
    kind=bare lit="" esc="" c="" i=0 v=0
    [ -n "$s" ] || kind=quoted
    while [ "$i" -lt "${#s}" ]; do
      c=${s:i:1}
      printf -v v '%d' "'$c"
      v=$((v & 255))
      if [ "$v" -lt 32 ] || [ "$v" -gt 126 ]; then
        kind=ansi
        printf -v c '\\x%02x' "$v"
        esc="$esc$c"
      else
        case $c in
          [A-Za-z0-9@%+=:,./_-]) ;;
          *) [ "$kind" = ansi ] || kind=quoted ;;
        esac
        case $c in
          "'") lit="$lit'\\''" esc="$esc\\'" ;;
          \\) lit="$lit$c" esc="$esc\\\\" ;;
          *) lit="$lit$c" esc="$esc$c" ;;
        esac
      fi
      i=$((i + 1))
    done
    printf '%s' "$sep"
    case $kind in
      bare) printf '%s' "$s" ;;
      quoted) printf "'%s'" "$lit" ;;
      ansi) printf "\$'%s'" "$esc" ;;
    esac
    sep=" "
  done
)

# _link_failed RC - report a non-zero do_link status and succeed, so the caller
# exits 1; a zero status fails, so the caller carries on. 2 is a manifest line
# the framework may not act on (every link was placed); anything else is a
# refused or failed link.
_link_failed() {
  case "$1" in
    0) return 1 ;;
    2) warn "the manifest keeps an entry the framework may not act on (see warnings above)" ;;
    *) warn "one or more links could not be created (see warnings above)" ;;
  esac
  return 0
}

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
# DEST<TAB>TARGET pairs for every manifest entry, kept beside the manifest so its
# format stays one bare path per line (lib/link.sh, "The targets file").
targets="$manifest_dir/targets"

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
LINK_TARGETS_SCRATCH=""
LINK_TARGETS=""
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
  [ -z "$LINK_TARGETS_SCRATCH" ] || rm -f -- "$LINK_TARGETS_SCRATCH"
  # A targets file staged but not yet renamed when the signal landed.
  _link_targets_discard
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
  LINK_TARGETS_SCRATCH="$(mktemp "$manifest_dir/.targets.XXXXXX")"
  LINK_TARGETS="$targets"
  local rc=0

  # ~/.zshenv is the only framework-managed file in $HOME; it
  # exports ZDOTDIR so the interactive config lives under $ZDOTDIR (XDG).
  link "$DOTFILES/zsh/zshenv" "$HOME/.zshenv" "$DOTFILES" || rc=1
  link "$DOTFILES/zsh/zshrc"  "$zdotdir/.zshrc" "$DOTFILES" || rc=1
  # Surface the .zshrc.local TEMPLATE beside where the user creates
  # .zshrc.local (the packages/*.local.example are read in place, so need no link).
  # Best-effort - a per-file `[ -e ] && link`, NOT link_tree,
  # which symlinks WHOLE config/ dirs, so their .example files ride inside the dir link, never
  # individually. A clone WITHOUT the template (a stripped subset, a minimal test fixture)
  # must not fail the install - it is an onboarding aid, not essential config. A real clone
  # always carries it, so it is linked there.
  [ -e "$DOTFILES/zsh/.zshrc.local.example" ] && \
    { link "$DOTFILES/zsh/.zshrc.local.example" "$zdotdir/.zshrc.local.example" "$DOTFILES" || rc=1; }

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
  # finalize's 2 (a refused manifest line kept, every link placed) passes
  # through as do_link's own 2, so the caller can say what it means.
  if [ "$rc" -eq 0 ]; then
    link_manifest_finalize "$manifest" "$DOTFILES" || rc=$?
  else
    link_manifest_merge "$manifest"
  fi
  rm -f -- "$LINK_MANIFEST" "$LINK_TARGETS_SCRATCH"
  LINK_TARGETS_SCRATCH=""
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
    warn "could not copy ~/.zsh_history to $(_shell_word "$dest") - starting with an empty history"
    return 0
  fi
  chmod 600 "$dest" 2>/dev/null \
    || warn "copied ~/.zsh_history to $(_shell_word "$dest") but could not chmod it 600 - check its permissions"
  log "carried ~/.zsh_history over to $(_shell_word "${dest#"$HOME"/}") (the original is untouched)"
}

# _cache_shell_inits - pre-compile the zsh integration the startup path sources:
# `<tool> init zsh` for starship and zoxide, `<tool> completion zsh` for the
# cobra-based CLIs canga and sbx. The startup path takes no subprocess
# (bin/startup-fork-gate proves it), and these tools ship their integration as
# a command to eval - so the fork happens HERE, once per install/upgrade,
# instead of once per shell.
#
# canga's and sbx's scripts are cobra's DYNAMIC completion: each asks its own
# binary's `__complete` on every TAB, so the subcommands a `canga upgrade` or an
# `sbx` release adds are offered without regenerating this cache. Only a change
# to cobra's script format would need a refresh, and the next link/upgrade
# provides it. Measured on sbx v0.45.1: the generated script's first line is
# `#compdef sbx` and exactly one line references `__complete`.
#
# Best-effort by design: a missing tool leaves no cache and zshrc's guard
# (binary present AND cache readable) then skips it silently. Written via a
# temp + mv so a half-written cache is never sourced. The cache lives under
# $XDG_CACHE_HOME/zsh - these ARE zsh scripts, and that is a directory
# `dotfiles-uninstall --purge` already sweeps, so the no-trace audit keeps
# holding without teaching uninstall a new path.
_cache_shell_inits() {
  local cache_dir="$xdg_cache/zsh" tool bin out tmp want first_line
  mkdir -p "$cache_dir" || { warn "could not create $(_shell_word "$cache_dir") - shell integrations will be skipped"; return 0; }
  for tool in starship zoxide canga sbx; do
    # A case, not a lookup table: bash 3.2 has no associative arrays. `set --`
    # carries the generator's argv, so the call below stays one quoted "$@".
    # `want` is the required first line of a completion script (empty for the
    # `init zsh` tools, which have no fixed shape to check).
    case "$tool" in
      # canga and sbx are OPTIONAL, like starship and zoxide, and neither is
      # installed by this framework. canga: https://github.com/brunovenceslau/canga.
      # sbx (the Docker Sandboxes CLI, Docker, Inc.) is a separate product this
      # framework never installs either.
      canga) out="$cache_dir/canga-completion.zsh"; set -- completion zsh; want="#compdef canga" ;;
      sbx)   out="$cache_dir/sbx-completion.zsh";   set -- completion zsh; want="#compdef sbx" ;;
      *)     out="$cache_dir/$tool-init.zsh";       set -- init zsh; want="" ;;
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
    # A prefix assignment scopes it to this one call; zoxide, canga and sbx ignore it.
    #
    # No time bound on the subprocess itself: bash 3.2 (macOS's /bin/bash, which
    # runs this installer) has no builtin timeout and ships no GNU `timeout` /
    # `gtimeout`, and a new dependency is ask-first. A pure-bash watchdog IS
    # possible - tests/lib/bounded_run.sh's job-control trick shows one - but is
    # not warranted for a measured 1.4s generator; that trick exists for the
    # test suite's own hermetic probes, which must survive an actual hang, not
    # this non-interactive installer.
    if STARSHIP_CACHE="$cache_dir/starship" "$bin" "$@" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      # `[ -s ]` alone accepts any non-empty noise (a warning banner, a partial
      # write). canga and sbx are cobra completion scripts; cobra's zsh
      # template emits `#compdef <tool>` first (measured on sbx v0.45.1:
      # `#compdef sbx`, and on canga v0.10.5's host build: `#compdef canga`,
      # then `compdef _canga canga`) - reject anything else so a malformed
      # generator output is never cached, exactly like an empty
      # one.
      first_line=""
      [ -z "$want" ] || first_line="$(head -n 1 -- "$tmp" 2>/dev/null)"
      if [ -n "$want" ] && [ "$first_line" != "$want" ]; then
        rm -f -- "$tmp"
        warn "$tool $* did not produce a completion script (want first line '$want') - its shell integration is skipped"
      else
        mv -f -- "$tmp" "$out"
        log "cached the $tool shell integration"
      fi
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
    || warn "submodule init failed; plugins may be absent - run: git -C $(_shell_word "$DOTFILES") -c fetch.fsckObjects=true -c transfer.fsckObjects=true submodule update --init --recursive"
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
  # `--` MUST precede the mode: macOS's chmod parses options with BSD getopt,
  # which stops at the first non-option (`go-w`), so a `--` after it is a FILE
  # operand ("chmod: --: No such file or directory", exit 1) and every install
  # printed the warning below although the tree was hardened. GNU getopt
  # permutes argv and accepts either order; the macOS CI legs ran the bad order
  # green because this function returns 0 whatever chmod does and no test read
  # the warning. tests/plugin_perms_test.sh case 4 now does.
  chmod -R -- go-w "$plugins" 2>/dev/null \
    || warn "could not remove group/other write from $(_shell_word "$plugins") - compinit may flag it as insecure"
  return 0
}

# do_uninstall [--purge] - reverse the install from the manifest.
# Remove only manifest-listed links + restore *.bak; --purge also
# clears generated state/cache. Continue-and-report like do_link: attempt every
# removal, return non-zero if any failed.
do_uninstall() {
  local purge=0 rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge) purge=1 ;;
      *) warn "uninstall: unknown option: $(_shell_word "$1") (expected: --purge)"; return 2 ;;
    esac
    shift
  done
  # Uninstall reads the pairs too: a link another checkout made is still the
  # framework's to remove (lib/link.sh, _link_owned). It never writes them.
  LINK_TARGETS="$targets"
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
    warn "  lock DIR: $(_shell_word "$lock")"
    warn "  if no upgrade is running, remove it (it is a directory):  rmdir $(_shell_word "$lock")"
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
# applies the OLD link rules to the NEW config, silently, with every gate green:
# the OLD exceptions table against a config/ tree whose rules have changed. A
# child re-reads the merged tree from disk.
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
# converge instead of returning success without doing anything. Otherwise a
# stale relink from an interrupted upgrade would stay wrong forever instead of
# for one cycle.
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
    warn "  Network unreachable? Check that first: the upstream HTTPS remote needs"
    warn "  no credentials to fetch."
    warn "  Credentials needed (a private fork, or an SSH remote)? The upgrade"
    warn "  fetch scrubs ~/.gitconfig and reads only the XDG config, so put a"
    warn "  credential helper there (gh writes an empty helper first, which"
    warn "  keeps a system helper such as osxkeychain from being asked first):"
    warn "    GIT_CONFIG_GLOBAL=\"\$HOME/.config/git/config.local\" gh auth setup-git"
    return 1
  fi
  if [ "$(vgit rev-parse FETCH_HEAD)" = "$(vgit rev-parse HEAD)" ]; then
    # A fresh fetch just confirmed there is nothing to pull - clear any stale
    # "available" sentinel a past cadence check left, so the precmd notice
    # stops nagging once we are already current.
    rm -f "$xdg_state/dotfiles/update-available"
    log "upgrade: already up to date"
    # Nothing to merge is NOT nothing to do - reconcile the installed
    # state against the current tree. Returning here unconditionally would make
    # the user's natural recovery (re-run dotfiles-upgrade) report success
    # forever while the links stayed wrong.
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

# do_identity --mode auto|identity|rotate|check [--name NAME] - derive this
# host's git identity and SSH signing key from its allowed-signers file and
# ssh-agent, and write them into $xdg_config/git/config.local (the same XDG
# path the link engine's ~/.config/git/config includes); rotate the key; or
# report a stale one. The logic is lib/host_identity.py: parsing quoted
# allowed-signers options is fragile in bash 3.2, and python3 ships with the
# Command Line Tools that git itself needs. `-I` keeps the cwd and PYTHON*
# variables out of its module path. Returns the script's status: 0 identity in
# place, 1 nothing decided, 2 usage. An unusable python3 is a skip with a
# warning (1).
#
# `--mode auto` is the automatic step the `install` and `link` arms run (and so
# every dotfiles-upgrade, which re-enters `link`): it writes only what is
# absent, is quiet once the host signs and has a user.name, prints ONE line
# (naming "$DOTFILES/install.sh identity" for the details) when it cannot act,
# which says every commit fails when the tracked commit.gpgsign = true is left
# with no signing key, prints one line naming `identity --name` while only
# user.name is missing (the tracked user.useConfigOnly = true makes git refuse
# every commit without it), does
# nothing in an SSH session (a forwarded agent holds another machine's keys),
# writes and prints nothing on a host that opted out of signing (a
# commit.gpgsign = false in config.local itself; `doctor` names it), never
# rotates a key and never writes user.name (the name is the operator's to
# choose: the line only suggests the account's full name, and
# `identity --name` writes it). With --report-stale (the `link` arm only, since
# `install` runs the fuller _signing_advisory right after), a host that already
# signs gets ONE line when its configured key no longer verifies (retired,
# expired or revoked). Its callers ignore its status: a host without an
# agent or a trust root still installs and upgrades. The upgrade's scrubbed
# git environment does not reach it: vgit scrubs per command and exports
# nothing, the step drops git's repository-local variables itself
# (lib/host_identity.py, GIT_LOCAL_ENV), and it refuses to write under a
# GIT_CONFIG_GLOBAL that is not the XDG config.
#
# The probe RUNS python3 rather than asking `command -v`: on a Mac without the
# Command Line Tools, /usr/bin/python3 exists as a stub that only offers to
# install them, so its presence proves nothing. Probed once per process.
_python_usable=""
_python_ok() {
  if [ -z "$_python_usable" ]; then
    if python3 -I -c '' >/dev/null 2>&1; then _python_usable=yes; else _python_usable=no; fi
  fi
  [ "$_python_usable" = yes ]
}
do_identity() {
  if ! _python_ok; then
    warn "identity: python3 is not usable here - skipping (install the Command Line Tools, then run $(_shell_word "$DOTFILES/install.sh") identity)"
    return 1
  fi
  python3 -I "$DOTFILES/lib/host_identity.py" --config-local "$xdg_config/git/config.local" \
    --installer "$DOTFILES/install.sh" "$@"
}

# do_doctor [--verbose] - `install.sh doctor`: lib/host_identity.py's
# read-only checks (its CHECKS registry): the identity and signing path, the
# plugin submodules of this checkout (the --installer path names it),
# Homebrew, gh (asked over the network whether GitHub accepts its token) and
# git's credential helper. It writes nothing that stays, prints only the
# problems (every check with --verbose) and returns 1 when it found one. A
# python3 that does not run is the one problem reported here, since the
# checks themselves need it.
do_doctor() {
  if ! _python_ok; then
    log "doctor: python3: python3 -I -c '' does not run here - install the Command Line Tools (xcode-select --install)"
    return 1
  fi
  python3 -I "$DOTFILES/lib/host_identity.py" --config-local "$xdg_config/git/config.local" \
    --installer "$DOTFILES/install.sh" --mode doctor "$@"
}

# authoring-side advisory, run by the `install` arm after the identity step.
# What it says is decided in ONE place, lib/host_identity.py's advisory()
# (`--mode check`): a host that cannot commit for want of a signing key, one
# that commits unsigned, a ~/.gitconfig that shadows
# the XDG config, a stale key, a signing setting that a later file overrides.
# It says nothing about signing on a host that opted out (a commit.gpgsign =
# false in config.local). Non-fatal. Quiet when python3 is unusable: the
# identity step, which runs first, already said so.
_signing_advisory() {
  command -v git >/dev/null 2>&1 || return 0
  # Before ANY git call: git opens the global chain at startup, config.local
  # include and all, even for a `git config --file` read, and a config.local
  # that is not a regular file (a FIFO) would hold every call. Only shell tests
  # run before this. The identity step, which runs first, has named it.
  if [ -e "$xdg_config/git/config.local" ] && [ ! -f "$xdg_config/git/config.local" ]; then
    return 0
  fi
  if _python_ok; then do_identity --mode check || :; fi
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
    [ $# -eq 0 ] || { warn "link takes no arguments (got: $(_shell_word "$@"))"; exit 2; }
    link_rc=0
    do_link || link_rc=$?
    # After the links, so `starship` resolves its config through the freshly linked
    # ~/.config/starship. `link` is the arm the upgrade re-enters in a fresh process,
    # so caching here is what keeps the init current across a tool version bump.
    # It runs even when a link was refused, for the reason the install arm gives.
    _cache_shell_inits
    harden_plugin_perms
    # The automatic identity step (see do_identity): `link` is the arm an upgrade
    # re-enters on the new tree, so a host gains its identity on its next
    # dotfiles-upgrade, and hears in one line when its key has gone stale.
    # Non-fatal, and it never changes this arm's exit status.
    do_identity --mode auto --report-stale || :
    _link_failed "$link_rc" && exit 1
    log "links (re)created."
    ;;
  reseed-settings)
    # RETIRED, and deliberately still here: this subcommand's NAME is a cross-version
    # ABI. The PREVIOUS release's installer invokes it on the NEW tree, so deleting the
    # arm would send that installer to the `*)` branch - exit 2, which _upgrade_apply
    # reports as a failed upgrade. It re-seeded the agent settings.json; there is no
    # longer a config surface that needs it, so it succeeds doing nothing.
    shift
    [ $# -eq 0 ] || { warn "reseed-settings takes no arguments (got: $(_shell_word "$@"))"; exit 2; }
    ;;
  install)
    # Reject arguments like the other arms: `install.sh` alone means install, so
    # drop the subcommand only when it was given, then nothing may remain.
    [ $# -eq 0 ] || shift
    [ $# -eq 0 ] || { warn "install takes no arguments (got: $(_shell_word "$@"))"; exit 2; }
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
    do_link || link_rc=$?
    # Materialize the SHA-pinned plugin submodules if a non-recursive clone left
    # them empty. link-only stays pure. Skipped after a refused link: that run
    # already ends in exit 1 and a re-run the user has to make, and the re-run
    # heals the submodules; fetching third-party code during a run that is
    # failing adds a network step (and its own failure modes) to a problem that
    # is purely local. Object fsck is not the reason - ensure_submodules forces
    # it itself.
    # A kept manifest line (2) placed every link, so it does not hold this back.
    if [ "$link_rc" -eq 0 ] || [ "$link_rc" -eq 2 ]; then
      ensure_submodules
    else
      warn "skipping plugin submodule init because a link was refused - re-run ./install.sh once it is fixed"
    fi
    harden_plugin_perms
    # Pre-compile the shell integrations the startup path sources (starship, zoxide,
    # canga's and sbx's completion) so `zsh -i` never forks to build one.
    _cache_shell_inits
    # The automatic identity step (see do_identity). Here, not through the link
    # arm, so it runs exactly once per install, and before the advisory, which
    # then reports what it left.
    do_identity --mode auto || :
    _signing_advisory   # warn if commit signing isn't set up yet
    if _link_failed "$link_rc"; then
      if [ "$link_rc" -eq 1 ]; then
        warn "  fix each refused path, then re-run ./install.sh"
      fi
      exit 1
    fi
    log "done - start a new zsh (e.g. \`exec zsh\`) to load the config."
    ;;
  upgrade)
    # Fetch -> ff-only merge -> submodules -> link -> recompile.
    # `dotfiles-upgrade` wraps this. No bypass flag by design - so reject any
    # argument rather than silently ignore a typo like `--dry-run`/`--force`.
    shift
    [ $# -eq 0 ] || { warn "upgrade takes no arguments (got: $(_shell_word "$@")) - there is no bypass flag by design"; exit 2; }
    do_upgrade || { warn "upgrade did not complete (see warnings above)"; exit 1; }
    ;;
  packages)
    # Install from the tracked manifests (+ untracked .local).
    # A separate subcommand - the default `install` links only, so `make smoke`
    # never triggers a package install (which needs the network). No sudo is
    # involved on that path either: Homebrew is user-scoped.
    shift
    [ $# -eq 0 ] || { warn "packages takes no arguments (got: $(_shell_word "$@"))"; exit 2; }
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
  identity)
    # Configure git identity + signing from the host. Unlike the install arm,
    # a refusal here is the answer the operator asked for, so it exits non-zero.
    # Each option is taken once, so a typo or a second value cannot silently win.
    shift
    id_name="" id_has_name=0 id_rotate=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --name | --name=*)
          [ "$id_has_name" -eq 0 ] || { warn "identity: --name given more than once"; exit 2; }
          if [ "$1" = --name ]; then
            [ $# -ge 2 ] || { warn "identity: --name needs a value"; exit 2; }
            id_name="$2"; shift
          else
            id_name="${1#--name=}"
          fi
          id_has_name=1; shift ;;
        --rotate)
          [ "$id_rotate" -eq 0 ] || { warn "identity: --rotate given more than once"; exit 2; }
          id_rotate=1; shift ;;
        *) warn "identity: unknown option: $(_shell_word "$1") (expected: --name \"Full Name\" | --rotate)"; exit 2 ;;
      esac
    done
    if [ "$id_rotate" -eq 1 ] && [ "$id_has_name" -eq 1 ]; then
      warn "identity: --rotate replaces only user.signingkey - run --name separately"; exit 2
    fi
    id_rc=0
    if [ "$id_rotate" -eq 1 ]; then
      do_identity --mode rotate || id_rc=$?
    elif [ "$id_has_name" -eq 1 ]; then
      # --name=VALUE, one argv word: a name that starts with a dash stays a value.
      do_identity --mode identity --name="$id_name" || id_rc=$?
    else
      do_identity --mode identity || id_rc=$?
    fi
    exit "$id_rc"
    ;;
  doctor)
    # Read only, so it is safe at any time; a problem found exits 1, so a
    # script can gate on it. --verbose is the only option.
    shift
    doc_args=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --verbose)
          [ -z "$doc_args" ] || { warn "doctor: --verbose given more than once"; exit 2; }
          doc_args=--verbose; shift ;;
        *) warn "doctor: unknown option: $(_shell_word "$1") (expected: --verbose)"; exit 2 ;;
      esac
    done
    doc_rc=0
    if [ -n "$doc_args" ]; then do_doctor --verbose || doc_rc=$?; else do_doctor || doc_rc=$?; fi
    exit "$doc_rc"
    ;;
  -h | --help | help)
    printf '%s\n' "usage: install.sh [install|link|packages|upgrade|uninstall [--purge]|identity [--name NAME] [--rotate]|doctor [--verbose]]"
    printf '%s\n' "       (retired, kept for cross-version compatibility: reseed-settings)"
    ;;
  *)
    warn "unknown command: $(_shell_word "$cmd") (expected: install | link | packages | upgrade | uninstall | identity | doctor | reseed-settings)"
    exit 2
    ;;
esac
fi
