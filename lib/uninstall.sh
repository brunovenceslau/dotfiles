# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# lib/uninstall.sh - reverse the link engine from the manifest.
#
# The uninstall counterpart to lib/link.sh. It is driven ENTIRELY by the manifest
# lib/link.sh writes ($XDG_STATE_HOME/dotfiles/manifest) - the single source of
# truth - so it can only ever remove links the installer actually
# created, never anything else. Sourced by install.sh's `uninstall`
# subcommand; the caller owns shell options and MUST define log()/warn() and set
# $DOTFILES (install.sh does both).
#
# Bash 3.2 compatible (no associative arrays, no mapfile, no
#   ${var,,}). No shebang / no `set` here.
# shellcheck shell=bash
# shellcheck disable=SC2329

# uninstall_links MANIFEST - remove every manifest-listed link and restore its
# backup, then prune the now-empty dirs the installer created.
# Remove ONLY manifest-listed links, restore *.bak, touch nothing the
#   installer did not create. A listed path is removed only if it is STILL a symlink
#   pointing into $DOTFILES - so a manifest entry the user has since replaced with
#   their own real file (or repointed elsewhere) is left untouched, and a tampered
#   manifest naming an arbitrary path (e.g. /etc/passwd) can never delete it.
uninstall_links() {
  local manifest="$1" dest target rc=0
  if [ ! -f "$manifest" ]; then
    warn "uninstall: no manifest at $manifest - nothing to remove"
    return 0
  fi

  # Read the manifest line by line (bash-3.2-safe: a while-read loop, no mapfile).
  # `|| [ -n "$dest" ]` so a final line without a trailing newline is still read.
  while IFS= read -r dest || [ -n "$dest" ]; do
    [ -n "$dest" ] || continue
    # link() only ever records absolute paths, so a relative line can only mean
    # tampering or corruption - and would otherwise resolve against the caller's
    # CWD. Reject the whole class; makes uninstall CWD-independent.
    case "$dest" in
      /*) ;;
      *) warn "uninstall: ignoring non-absolute manifest line: $dest"; continue ;;
    esac
    if [ -L "$dest" ]; then
      target="$(readlink "$dest")"
      case "$target" in
        "$DOTFILES"/*)
          if rm -f -- "$dest"; then log "removed link $dest"; else rc=1; fi
          ;;
        *)
          warn "uninstall: $dest no longer points into the repo (-> $target) - leaving it"
          ;;
      esac
    elif [ -e "$dest" ]; then
      # A real file/dir sits where our link was: the user replaced it. Leave it.
      warn "uninstall: $dest is not our symlink anymore - leaving it"
    fi
    # Restore the pre-framework file link() backed up, if any. Done
    # after removing the link so the restored file lands on a clear path.
    if [ -e "$dest.bak" ] || [ -L "$dest.bak" ]; then
      if [ -e "$dest" ] || [ -L "$dest" ]; then
        warn "uninstall: not restoring $dest.bak - something occupies $dest"
      elif mv -- "$dest.bak" "$dest"; then
        log "restored $dest from .bak"
      else
        rc=1
      fi
    fi
    # Prune dirs the installer created once they are empty (rmdir only removes an
    # empty dir, so a dir still holding a user file - e.g. a .local - is preserved).
    _uninstall_prune_dirs "$(dirname "$dest")"
  done < "$manifest"

  return "$rc"
}

# _uninstall_prune_dirs DIR - rmdir DIR and its ancestors while each is empty,
# stopping at $HOME (never removing $HOME itself). Best-effort: a non-empty dir
# (rmdir fails) ends the climb, so a directory that still holds a user file - a
# `.local`, a pre-existing config - is never removed.
_uninstall_prune_dirs() {
  local dir="$1"
  while [ -n "$dir" ] && [ "$dir" != "$HOME" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do
    case "$dir" in
      "$HOME"/*) ;;                 # only ever prune under $HOME
      *) return 0 ;;
    esac
    rmdir -- "$dir" 2>/dev/null || return 0   # non-empty (or gone) -> stop
    dir="$(dirname "$dir")"
  done
}

# uninstall_purge - remove framework-generated state/cache, leaving zero
# framework-created files. ONLY these three trees, all XDG
# subdirs the framework owns end-to-end; user `.local` files live under
# $XDG_CONFIG_HOME/zsh, which is deliberately NOT touched here.
# The FAST_WORK_DIR cache lives under $XDG_CACHE_HOME/zsh (see zsh/zshrc), so it
# is covered by the first path - no separate entry needed.
uninstall_purge() {
  local xdg_cache="${XDG_CACHE_HOME:-$HOME/.cache}"
  local xdg_state="${XDG_STATE_HOME:-$HOME/.local/state}"
  local cfg_zsh="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"
  local d rc=0
  for d in "$xdg_cache/zsh" "$xdg_state/zsh" "$xdg_state/dotfiles"; do
    # Containment before rm -rf - the same discipline _uninstall_prune_dirs has.
    # The XDG vars come from the caller's env; install-time trust is symmetric,
    # but the CONSEQUENCE is not (a mispointed install misplaces symlinks -
    # recoverable; a mispointed purge is rm -rf). Refuse anything not strictly
    # under $HOME (also rejects relative values, which would resolve against the
    # CWD), and never the .local home ($XDG_CONFIG_HOME/zsh) even when a
    # misconfigured XDG var derives to it - "never touched".
    case "$d" in
      "$HOME"/*) ;;
      *) warn "uninstall: refusing to purge $d - not under \$HOME"; rc=1; continue ;;
    esac
    if [ "$d" = "$cfg_zsh" ]; then
      warn "uninstall: refusing to purge $d - the .local layer lives there"; rc=1; continue
    fi
    if [ -e "$d" ]; then
      if rm -rf -- "$d"; then log "purged $d"; else warn "uninstall: could not purge $d"; rc=1; fi
      _uninstall_prune_dirs "$(dirname "$d")"
    fi
  done
  return "$rc"
}
