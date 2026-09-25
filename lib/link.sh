# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# lib/link.sh - the convention-based link engine.
#
# Two layers: the backup-aware link() primitive and the convention walker
# link_tree() with its uninstall manifest. link_tree() maps the
# repo's config/, home/ and bin/ trees onto their XDG/HOME destinations, applies
# the exceptions table (gnupg partial; rclone/
# restic never; the bin/ dev gates never), and records every created link so uninstall has a single source
# of truth. The backup contract link() implements is documented at link()
# itself, just below.
#
# Bash 3.2 compatible (no associative arrays, no mapfile,
#   no ${var,,}). Sourced by install.sh, so no shebang and no `set` here - the
#   caller owns shell options. Callers MUST define log()/warn() and MUST source
#   (install.sh does both). The shellcheck directives pick the bash dialect and
#   silence SC2329 (these helpers are invoked by the caller, not called here).
# shellcheck shell=bash
# shellcheck disable=SC2329

# link SRC DEST - make DEST a symlink to SRC, idempotently.
# A pre-existing regular file is backed up to DEST.bak before
#   replacement; an existing symlink (including a dangling one) is replaced
#   without a backup; a regular directory at DEST is refused loudly (its
#   backup/restore idempotency differs - explicit user action is required).
# When DEST already is the intended symlink the call is a no-op,
#   so a re-run creates no new .bak and leaves every link identical.
link() {
  local src="$1" dest="$2"

  if [ ! -e "$src" ] && [ ! -L "$src" ]; then
    warn "link: source missing, skipping: $src"
    return 1
  fi

  if [ -L "$dest" ]; then
    # Already pointing where we want -> nothing to do (idempotent re-run). The
    # link still exists, so it is still ours to record: a re-run
    # must reproduce the full manifest, not an empty one.
    if [ "$(readlink "$dest")" = "$src" ]; then
      _link_record "$dest"
      return 0
    fi
    # Any other symlink, dangling included: replace it, no backup.
    # `--` so a target name that begins with '-' is never read as an option.
    rm -f -- "$dest"
  elif [ -d "$dest" ]; then
    warn "link: refusing to replace an existing directory: $dest"
    warn "      move or remove it by hand, then re-run install."
    return 1
  elif [ -e "$dest" ]; then
    # Regular file: preserve the user's copy before overwriting.
    # Never clobber an existing backup - the first .bak is the pristine
    # pre-framework file and is the one worth keeping; refuse loudly instead.
    if [ -e "$dest.bak" ]; then
      warn "link: backup already exists, refusing to overwrite: $dest.bak"
      warn "      move or remove it by hand, then re-run install."
      return 1
    fi
    mv -f -- "$dest" "$dest.bak"
    log "backed up $dest -> $dest.bak"
  fi

  mkdir -p "$(dirname "$dest")"
  ln -s -- "$src" "$dest"
  log "linked $dest -> $src"
  _link_record "$dest"
}

# --- Manifest -----------------------------------------------------------------
# Every created link is recorded so $XDG_STATE_HOME/dotfiles/
#   manifest is the sole source of truth for uninstall. Recording is opt-in: a
#   caller sets $LINK_MANIFEST to a scratch collection file before linking; the
#   isolated link() unit test leaves it unset and nothing is written.
_link_record() {
  [ -n "${LINK_MANIFEST-}" ] || return 0
  printf '%s\n' "$1" >> "$LINK_MANIFEST"
}

# link_manifest_finalize DEST [ROOT] - publish EXACTLY the recorded links as the
# manifest at DEST (replace), sorted and deduped so the file is byte-stable across
# identical re-runs. This is the happy-path publish: a link that is
# no longer produced (e.g. a removed config) drops from the manifest.
# `LC_ALL=C` makes the ordering locale-independent; the temp is a mktemp sibling
# of DEST so the rename is atomic and never leaves a half-written manifest.
#
# When ROOT is given, before publishing, reclaim on-disk ORPHANS -
# a link the PREVIOUS manifest recorded that this run no longer produces, and that
# is still a symlink pointing into ROOT, is unlinked with the EXACT predicate
# uninstall uses: a real file, or a symlink pointing outside ROOT,
# is left untouched. Dropping the entry from the manifest without unlinking the
# stale symlink is what leaves an unmanaged orphan on disk - the shape a dropped
# config/<prog> tree produces: source gone, rule gone, link still there. ROOT
# empty (a fixture, or a caller that does not opt in) disables the prune, so it
# never fires without a repo root to judge containment against. This
# runs ONLY here on the clean finalize path - never in link_manifest_merge, whose
# superset must not drop a still-live link on an interrupted run.
link_manifest_finalize() {
  local dest="$1" root="${2-}" tmp old d t
  [ -n "${LINK_MANIFEST-}" ] || return 0
  tmp="$(mktemp "$dest.XXXXXX")" || return 1
  if ! LC_ALL=C sort -u "$LINK_MANIFEST" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [ -n "$root" ] && [ -f "$dest" ]; then
    old="$(mktemp "$dest.old.XXXXXX")" || { rm -f -- "$tmp"; return 1; }
    LC_ALL=C sort -u "$dest" > "$old"
    # comm -23 OLD NEW = entries in the previous manifest no longer produced.
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      # Reject a non-absolute line FIRST, exactly as uninstall does
      # (lib/uninstall.sh) - a corrupt/legacy relative entry must not resolve
      # against the invocation CWD. Then unlink only a symlink into $root.
      case "$d" in
        /*) ;;
        *) warn "prune: ignoring non-absolute manifest line: $d"; continue ;;
      esac
      [ -L "$d" ] || continue
      t="$(readlink "$d")"
      case "$t" in
        "$root"/*) rm -f -- "$d" && log "pruned orphan link $d (no longer produced)" ;;
        *) warn "prune: $d no longer produced but points outside the repo (-> $t) - leaving it" ;;
      esac
    done < <(LC_ALL=C comm -23 "$old" "$tmp")
    rm -f -- "$old"
  fi
  mv -f -- "$tmp" "$dest"
}

# link_manifest_merge DEST - UNION the recorded links into an existing manifest at
# DEST (superset), never dropping a prior entry. This is the abnormal-exit path:
# if a link conflict aborts the walk under set -e before finalize, the links
# already created on disk must still be recorded or a later
# uninstall would orphan them. A superset is safe - uninstall's rm -f no-ops on an
# already-absent link. No-op unless the scratch actually holds created links.
link_manifest_merge() {
  local dest="$1" tmp
  [ -n "${LINK_MANIFEST-}" ] && [ -s "$LINK_MANIFEST" ] || return 0
  tmp="$(mktemp "$dest.XXXXXX")" || return 1
  if [ -f "$dest" ]; then
    LC_ALL=C sort -u "$LINK_MANIFEST" "$dest" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  else
    LC_ALL=C sort -u "$LINK_MANIFEST" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  mv -f -- "$tmp" "$dest"
}

# --- Convention walker --------------------------------------------------------
# link_tree ROOT - place every conventional link under ROOT, honoring the OS
# suffix and the exceptions table. Destinations follow the XDG/HOME fallbacks
# (same as zsh/zshenv and install.sh). Records every placed link into
# $LINK_MANIFEST when set. Continue-and-report: a refused link (a conflict) never
# aborts the walk - every other link is still placed - but link_tree RETURNS
# NON-ZERO if any link was refused, so the installer can fail loudly after doing
# all the safe work. This is explicit rather than relying on `set -e`, which a
# for-loop body silently swallows.
link_tree() {
  local root="$1" rc=0
  _link_config_tree "$root" "${XDG_CONFIG_HOME:-$HOME/.config}" || rc=1
  _link_home_tree "$root" || rc=1
  _link_bin_tree "$root" || rc=1
  return "$rc"
}

# config/<prog>/ -> ~/.config/<prog>.
# NO @suffix is recognized. macOS is the only target, so the @darwin gate this
#   engine used to honour could only ever be true; it is gone, and @darwin now
#   warns like any other suffix rather than being silently stripped. The
#   convention carries no architecture suffix either - arch differences live in
#   shell guards, Brewfile on_arm/on_intel, or .local, never in a link name.
# The exceptions table (gnupg partial; rclone/restic never).
_link_config_tree() {
  local root="$1" cfg="$2" dir base prog rc=0
  [ -d "$root/config" ] || return 0
  for dir in "$root"/config/*; do
    [ -d "$dir" ] || continue          # real subdirs only; also skips glob-nomatch
    base="${dir##*/}"
    case "$base" in
      # No @suffix is recognized: macOS is the only target, so an OS-gated
      # directory has nothing to gate against. Any @suffix is a likely typo.
      *@*) warn "link: unknown OS suffix on config/$base - skipping"; continue ;;
      *)   prog="$base" ;;
    esac
    case "$prog" in
      gnupg)         _link_gnupg "$dir" || rc=1 ;;              # selective
      git)           _link_git "$dir" "$cfg" "$root" || rc=1 ;;  # (write-back)
      rclone|restic) : ;;                                       # secrets
      *)             link "$dir" "$cfg/$prog" || rc=1 ;;        # the convention
    esac
  done
  return "$rc"
}

# Gnupg links ONLY these two files into ~/.gnupg and never the
#   directory itself - the real ~/.gnupg holds live secret keyrings and must not
#   become a symlink into the repo.
# Secret hygiene: when the framework is the first to create ~/.gnupg (where the
#   user's secret keyrings will later live), create it 0700 under a tight umask so
#   gpg does not warn about unsafe permissions and no other local user can
#   traverse it. An existing ~/.gnupg is left untouched (respect the user's mode).
_link_gnupg() {
  local dir="$1" name rc=0
  [ -d "$HOME/.gnupg" ] || ( umask 077 && mkdir -p -- "$HOME/.gnupg" )
  for name in gpg.conf gpg-agent.conf; do
    [ -e "$dir/$name" ] || continue
    link "$dir/$name" "$HOME/.gnupg/$name" || rc=1
  done
  return "$rc"
}

# An exception to the whole-dir convention: ~/.config/git/config is the XDG
#   global git config - the path `git config --global` WRITES to. Symlinking the
#   whole config/git dir (the default) makes that path the TRACKED
#   config/git/config, so every global write lands in the source of truth
#   (measured live: `safe.directory = *`, which would have disabled git's
#   ownership check on every clone). A tracked file MUST NOT be a tool's writable config
#   path, so instead ~/.config/git/config is a real, machine-local file that git
#   natively [include]s the tracked config. Writes land locally; tracked content is
#   still honored. It is NOT recorded in the manifest - uninstall must not delete a
#   machine-local file. Idempotent: an existing real file is left intact.
_link_git() {
  local dir="$1" cfg="$2" root="$3"
  local gitdir="$cfg/git" dest="$cfg/git/config" tracked="$dir/config" target
  [ -e "$tracked" ] || return 0   # a stripped subset without the tracked config: nothing to do
  # (1) Convert a WHOLE-DIR symlink into the repo (~/.config/git -> repo/config/git),
  #     which would make the tracked config git's global write target: remove ONLY
  #     the link (never its target) so a real dir can hold the local file.
  if [ -L "$gitdir" ]; then
    target="$(readlink "$gitdir")"
    case "$target" in
      "$root"/*)
        if rm -f -- "$gitdir"; then
          log "git: converted stale ~/.config/git dir symlink to a real dir"
        else
          warn "git: could not remove the stale ~/.config/git symlink"; return 1
        fi
        ;;
      *) log "git: leaving a foreign ~/.config/git symlink intact ($gitdir -> $target)"; return 0 ;;
    esac
  fi
  mkdir -p -- "$gitdir" || { warn "git: could not create $gitdir"; return 1; }
  # (1b) The global ignore list: git reads $XDG_CONFIG_HOME/git/ignore natively, so
  #      a plain link puts it exactly where git already looks and no
  #      core.excludesfile (an absolute path) is needed. Unlike `config` below, this
  #      file is wholly ours - nothing writes to it - so it is a normal managed link
  #      and IS manifested, which means uninstall removes it.
  if [ -e "$dir/ignore" ]; then
    link "$dir/ignore" "$gitdir/ignore" || return 1
  fi
  # (2) The config FILE: seed a real local include-file when absent, convert a stale
  #     symlink INTO the repo, and never clobber an existing real (machine-local) file.
  if [ -L "$dest" ]; then
    target="$(readlink "$dest")"
    case "$target" in
      "$root"/*)
        rm -f -- "$dest" \
          || { warn "git: could not remove the stale ~/.config/git/config symlink"; return 1; }
        _write_git_local_config "$dest" "$tracked" || return 1
        ;;
      *) log "git: leaving a foreign ~/.config/git/config symlink intact"; return 0 ;;
    esac
  elif [ ! -e "$dest" ]; then
    _write_git_local_config "$dest" "$tracked" || return 1
  else
    log "git: ~/.config/git/config exists - leaving the machine-local file intact"
  fi
}

# _write_git_local_config DEST TRACKED - write a real, machine-local git config at
# DEST that [include]s the TRACKED config by ABSOLUTE path (a relative include would
# resolve against ~/.config/git, not the repo). The tracked config carries its own
# relative `[include] config.local` -> <repo>/config/git/config.local, which keeps
# a config.local that sits in the checkout working after step (1) converts a
# whole-dir symlink. The second, relative include below resolves ~/.config/git/config.local -
# where the host's git identity and signing key are written on a FRESH
# install - so BOTH includes are load-bearing: trimming the second would silently
# break signing resolution on a fresh host. Written via a mktemp sibling + mv so
# a partial write never leaves a half-formed global config. bash 3.2: no arrays.
_write_git_local_config() {
  local dest="$1" tracked="$2" tmp
  tmp="$(mktemp "$dest.XXXXXX")" || { warn "git: could not stage $dest"; return 1; }
  {
    printf '%s\n' '# ~/.config/git/config - machine-local git config, created by the dotfiles'
    printf '%s\n' '# installer. A REAL file, NEVER a symlink into the tracked'
    printf '%s\n' "# config: keeping it local is what stops \`git config --global\` from writing"
    printf '%s\n' '# into the tracked (published) config/git/config. It [include]s that tracked'
    printf '%s\n' '# config (which in turn [include]s its own config.local), so every portable'
    printf '%s\n' '# setting and the host identity still resolve; global writes land here.'
    printf '[include]\n'
    printf '\tpath = %s\n' "$tracked"
    printf '%s\n' '# Machine-local overrides may also live next to this file, as config.local'
    printf '%s\n' '# (the documented ~/.config/git/config.local layer). Relative -> resolves here.'
    printf '[include]\n'
    printf '\tpath = config.local\n'
  } > "$tmp" || { rm -f -- "$tmp"; warn "git: could not write $dest"; return 1; }
  mv -f -- "$tmp" "$dest" \
    || { rm -f -- "$tmp"; warn "git: could not install $dest"; return 1; }
  log "git: wrote machine-local $dest that [include]s the tracked config"
}

# home/<file> -> ~/.<file> (the leading dot is added at the target;
#   entries under home/ are named without it).
_link_home_tree() {
  local root="$1" f base rc=0
  [ -d "$root/home" ] || return 0
  for f in "$root"/home/*; do
    # `-e` skips glob-nomatch; `-L` still admits a (possibly dangling) symlink so
    # it reaches link()'s own source check rather than being dropped silently.
    { [ -e "$f" ] || [ -L "$f" ]; } || continue
    base="${f##*/}"
    link "$f" "$HOME/.$base" || rc=1
  done
  return "$rc"
}

# bin/* -> ~/.local/bin/*, minus the repo's own quality gates.
# The gates (check-patterns, secret-scan, smoke, startup-fork-gate,
#   repo-settings-check) are developer tools that `make` runs from the
#   checkout. They MUST NOT land on a user's PATH: their generic names (`smoke`)
#   shadow other tools, and they locate the repo from `dirname "$0"`, so run
#   through a ~/.local/bin link they fail with "does not look like the dotfiles
#   repo". tests/link_engine_test.sh fails when a
#   bin/ tool the Makefile calls is missing from this list, so a new gate cannot
#   leak onto PATH by omission. A host upgrading from a release that linked them
#   gets those links pruned as orphans (link_manifest_finalize), since they point
#   into the repo and are no longer produced.
_link_bin_tree() {
  local root="$1" f base rc=0
  [ -d "$root/bin" ] || return 0
  for f in "$root"/bin/*; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue    # admit dangling symlinks too
    base="${f##*/}"
    case "$base" in
      check-patterns | secret-scan | smoke | startup-fork-gate | repo-settings-check) continue ;;   # dev gates
    esac
    link "$f" "$HOME/.local/bin/$base" || rc=1
  done
  return "$rc"
}
