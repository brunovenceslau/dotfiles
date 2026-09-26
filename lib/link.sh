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

# link SRC DEST [ROOT] - make DEST a symlink to SRC, idempotently.
# ROOT is the repo checkout SRC lives in; it decides whose an existing symlink is.
# The backup contract, per state of DEST:
#   - the intended symlink already: a no-op (still recorded), so a re-run creates
#     no new .bak and leaves every link identical;
#   - a symlink pointing INTO ROOT (a stale framework link, dangling or not), or
#     one whose destination and live target $LINK_TARGETS records as a pair (a
#     link another checkout of the framework made): replaced without a backup -
#     it is the framework's, not user data;
#   - any other symlink (the user's, dangling included) or a regular file: moved
#     to DEST.bak, then replaced. mv renames the link itself, so the .bak keeps the
#     original target byte for byte and uninstall's mv back restores it as a link;
#   - a regular directory: refused loudly (its backup/restore idempotency
#     differs - explicit user action is required).
# ROOT empty classifies nothing as in-repo, so every foreign symlink is backed up:
#   an unknown root must err toward keeping user data, never toward deleting it.
# A DEST _link_under_home refuses (outside $HOME, or through a symlinked parent
#   out of it or into ROOT) is refused loudly and returns 1, like a conflict.
link() {
  local src="$1" dest="$2" root="${3-}"

  if [ ! -e "$src" ] && [ ! -L "$src" ]; then
    warn "link: source missing, skipping: $src"
    return 1
  fi
  # Install and uninstall agree on where the framework may act: a destination
  # uninstall would refuse (outside $HOME, or through a parent inside ROOT) is
  # never created, so it can never be left behind.
  if ! _link_under_home "$dest" "$root"; then
    warn "link: refusing $dest - $LINK_REFUSAL"
    return 1
  fi

  if [ -L "$dest" ]; then
    # Already pointing where we want -> nothing to do (idempotent re-run). The
    # link still exists, so it is still ours to record: a re-run
    # must reproduce the full manifest, not an empty one.
    if [ "$(readlink "$dest")" = "$src" ]; then
      _link_record "$dest" "$src"
      return 0
    fi
    if _link_owned "$dest" "$root"; then
      # A stale framework link: ours to replace, no backup.
      # `--` so a target name that begins with '-' is never read as an option.
      rm -f -- "$dest"
    else
      _link_backup "$dest" || return 1
    fi
  elif [ -d "$dest" ]; then
    warn "link: refusing to replace an existing directory: $dest"
    warn "      move or remove it by hand, then re-run install."
    return 1
  elif [ -e "$dest" ]; then
    _link_backup "$dest" || return 1
  fi

  # Checked, and recorded only on success: a manifest entry must name a link that
  # exists (a dangling parent symlink makes both steps fail).
  mkdir -p -- "$(dirname "$dest")" || { warn "link: could not create the parent of $dest"; return 1; }
  ln -s -- "$src" "$dest" || { warn "link: could not create $dest"; return 1; }
  log "linked $dest -> $src"
  _link_record "$dest" "$src"
}

# _link_backup DEST - move the user's DEST (a regular file or a foreign symlink)
# to DEST.bak. Never clobber an existing backup - the first .bak is the pristine
# pre-framework copy and is the one worth keeping; refuse loudly instead. `-L` as
# well as `-e`: a backed-up dangling symlink fails `-e`, and it is still the
# pristine .bak.
_link_backup() {
  local dest="$1"
  if [ -e "$dest.bak" ] || [ -L "$dest.bak" ]; then
    warn "link: backup already exists, refusing to overwrite: $dest.bak"
    warn "      move or remove it by hand, then re-run install."
    return 1
  fi
  mv -f -- "$dest" "$dest.bak"
  log "backed up $dest -> $dest.bak"
}

# _link_owned DEST ROOT - THE ownership predicate: succeed when the symlink DEST
# is the framework's, i.e. it points into ROOT (_link_points_into) or
# $LINK_TARGETS records exactly its destination and live target
# (_link_pair_recorded, a link another checkout made). Every site that decides
# "remove without a backup" asks this and nothing else: link(), prune
# (link_manifest_finalize), uninstall (uninstall_links) and both _link_git
# conversions. One predicate, so a target spelled with `..` or through an alias
# cannot be the user's at one site and the framework's at another.
_link_owned() {
  [ -L "$1" ] || return 1
  _link_points_into "$1" "$2" || _link_pair_recorded "$1"
}

# _link_under_home PATH [ROOT] - succeed when the framework may create, remove or
# restore PATH: PATH is spelled strictly under $HOME with no "." or ".."
# component, AND its parent directory, resolved physically, is $HOME or below it
# and (unless $HOME itself is inside ROOT) not inside ROOT. The spelling check stops "$HOME/../x"; the physical
# check stops a symlinked parent (a redirected ~/.config, or a directory link
# into the checkout) from carrying an rm or a restore somewhere else. link(),
# prune, uninstall and its directory pruning and purge all ask this, so what
# install may create is exactly what uninstall may remove.
# $HOME is compared without trailing slashes; an unset, empty, relative or "/"
# $HOME, or one that resolves to "/", contains nothing. A PATH ending in "/" is
# refused (it names a directory the caller never records). PATH itself being
# ROOT, or an ancestor of it, is refused too: the parent check alone would let
# an rm -rf of "$XDG_STATE_HOME/dotfiles" take the checkout when they coincide.
_link_under_home() {
  local p="$1" root="${2-}" h ph pp pr
  # The reason a refusal names, read by the caller right after a failure: the
  # default, unless the check that failed is one of the two against ROOT below.
  # A global, not output, because every caller asks from an `if !` in-process.
  LINK_REFUSAL="outside the home directory"
  h="${HOME-}"
  while [ "${h%/}" != "$h" ]; do h="${h%/}"; done
  case "$h" in
    /?*) ;;
    *) return 1 ;;
  esac
  case "$p" in
    */) return 1 ;;
    "$h"/?*) ;;
    *) return 1 ;;
  esac
  case "$p/" in
    */../* | */./*) return 1 ;;
  esac
  ph="$(cd -P -- "$h" 2>/dev/null && pwd -P)" || return 1
  [ "$ph" != "/" ] || return 1
  pp="$(dirname "$p")"
  # The parent is resolved in FULL when it exists - unlike a link target, its
  # own last component is a directory the rm or restore goes through. A missing
  # parent (link() creates it) resolves as far as it exists.
  if [ -d "$pp" ]; then
    pp="$(cd -P -- "$pp" 2>/dev/null && pwd -P)" || return 1
  else
    pp="$(_link_physical "$pp")" || return 1
  fi
  case "$pp" in
    "$ph" | "$ph"/*) ;;
    *)
      # A parent that leads out of $HOME and into ROOT is named as the checkout,
      # the more specific of the two reasons.
      if [ -n "$root" ] && pr="$(cd -P -- "$root" 2>/dev/null && pwd -P)"; then
        case "$pp" in
          "$pr" | "$pr"/*) LINK_REFUSAL="inside the checkout" ;;
        esac
      fi
      return 1
      ;;
  esac
  # Inside ROOT is refused only when $HOME itself is not: a scratch HOME kept
  # inside the checkout (make smoke) is all "inside ROOT", and there the check
  # above already keeps the parent within that HOME, off the rest of the tree.
  if [ -n "$root" ]; then
    pr="$(cd -P -- "$root" 2>/dev/null && pwd -P)" || return 1
    case "$pr/" in
      "${pp%/}/${p##*/}"/*) LINK_REFUSAL="inside the checkout"; return 1 ;;
    esac
    case "$ph" in
      "$pr" | "$pr"/*) ;;
      *)
        case "$pp" in
          "$pr" | "$pr"/*) LINK_REFUSAL="inside the checkout"; return 1 ;;
        esac
        ;;
    esac
  fi
  return 0
}

# _link_points_into DEST ROOT - succeed when the symlink DEST points INTO ROOT,
# i.e. its target, resolved against DEST's own directory when relative, lies
# strictly below ROOT once both are compared as PHYSICAL paths. Physical, because
# the same checkout is reachable by more than one spelling (a symlinked checkout,
# /var vs /private/var on macOS); the trailing "/" in the match is what keeps a
# prefix lookalike (<root>-host) outside. The target's FINAL component is not
# followed: a link to the user's own symlink is the user's, whatever that
# symlink points at. Any doubt (empty ROOT, unresolvable path) answers "no", so
# the caller backs up rather than deletes. Portable on purpose - macOS readlink
# has no -f - so resolution is `cd -P` + `pwd -P` in a subshell; install-time
# only, never on the zsh startup path.
_link_points_into() {
  local dest="$1" root="$2" t proot
  [ -n "$root" ] || return 1
  proot="$(cd -P -- "$root" 2>/dev/null && pwd -P)" || return 1
  t="$(readlink "$dest")" || return 1
  case "$t" in
    /*) ;;
    *) t="$(dirname "$dest")/$t" ;;
  esac
  t="$(_link_physical "$t")" || return 1
  case "$t" in
    "$proot"/*) return 0 ;;
  esac
  return 1
}

# _link_physical PATH - print absolute PATH with every EXISTING directory prefix
# resolved physically; the missing remainder (a dangling target) is appended
# verbatim. A "." or ".." inside that missing remainder has no physical meaning,
# so it fails rather than being collapsed lexically into a path it may not name.
_link_physical() {
  local p="$1" head base tail="" phys
  case "$p" in
    /*) ;;
    *) return 1 ;;
  esac
  while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  [ "$p" != "/" ] || { printf '/\n'; return 0; }
  base="${p##*/}"
  head="${p%/*}"
  [ -n "$head" ] || head="/"
  case "$base" in
    . | ..)
      phys="$(cd -P -- "$p" 2>/dev/null && pwd -P)" || return 1
      printf '%s\n' "$phys"
      return 0
      ;;
  esac
  while [ ! -d "$head" ]; do
    case "${head##*/}" in
      . | ..) return 1 ;;
    esac
    tail="${head##*/}/$tail"
    head="${head%/*}"
    [ -n "$head" ] || head="/"
  done
  phys="$(cd -P -- "$head" 2>/dev/null && pwd -P)" || return 1
  printf '%s\n' "${phys%/}/$tail$base"
}

# --- Manifest -----------------------------------------------------------------
# Every created link is recorded so $XDG_STATE_HOME/dotfiles/
#   manifest is the sole source of truth for uninstall. Recording is opt-in: a
#   caller sets $LINK_MANIFEST to a scratch collection file before linking; the
#   isolated link() unit test leaves it unset and nothing is written.
#
# The targets file ($LINK_TARGETS, published; $LINK_TARGETS_SCRATCH, this run's
#   collection) holds one "DEST<TAB>TARGET" pair per framework link, beside the
#   manifest and never inside it: the previous release's uninstall reads every
#   manifest line as a bare path, so a second field there would make it skip
#   every entry. The pair is what lets a relink from ANOTHER checkout recognize
#   a link the framework made (link() -> _link_pair_recorded). Both variables
#   unset (the unit tests) disables pairs: nothing is written, nothing matches.
_link_record() {
  [ -n "${LINK_MANIFEST-}" ] || return 0
  printf '%s\n' "$1" >> "$LINK_MANIFEST"
  [ -n "${LINK_TARGETS_SCRATCH-}" ] || return 0
  # A tab or newline would forge or split a pair line, so such a pair is never
  # written. No pair fails closed: a later relink from another checkout backs
  # the link up instead of replacing it.
  if _link_pair_safe "$1" "$2"; then
    printf '%s\t%s\n' "$1" "$2" >> "$LINK_TARGETS_SCRATCH"
  else
    warn "link: not recording the target of $1 (tab or newline in the path) - another checkout will back it up"
  fi
}

# _link_pair_safe DEST TARGET - succeed when neither holds a tab or a newline.
_link_pair_safe() {
  case "$1$2" in
    *"$_link_tab"* | *"$_link_nl"*) return 1 ;;
  esac
  return 0
}
# A literal tab and newline for pattern matching, set once at source time.
_link_tab="$(printf '\t')"
_link_nl='
'

# _link_readlink DEST - print the target of DEST exactly. $(readlink) alone would
# strip trailing newlines and so let a target "T<newline>" pass for "T"; the
# sentinel keeps them, and only readlink's own final newline is removed.
_link_readlink() {
  local t
  t="$(readlink "$1" && printf x)" || return 1
  t="${t%x}"
  printf '%s' "${t%"$_link_nl"}"
}

# _link_pair_recorded DEST - succeed when $LINK_TARGETS holds exactly the pair
# "DEST<TAB>live target of DEST". A missing file, a missing pair, a different
# target (the user repointed a recorded destination) or an unsafe path all fail,
# which the caller turns into a backup.
_link_pair_recorded() {
  local dest="$1" t
  [ -n "${LINK_TARGETS-}" ] || return 1
  _link_targets_usable || return 1
  [ -f "$LINK_TARGETS" ] || return 1
  t="$(_link_readlink "$dest" && printf x)" || return 1
  t="${t%x}"
  _link_pair_safe "$dest" "$t" || return 1
  grep -qxF -- "$(printf '%s\t%s' "$dest" "$t")" "$LINK_TARGETS"
}

# _link_targets_usable - fail when $LINK_TARGETS is a symlink. The state dir is
# the user's, but a symlinked targets file would let whatever it points at
# decide which links are replaced without a backup, so it is ignored (no pairs:
# every foreign link is backed up) and the next publish renames a real file over
# the link. Warns once per run.
_link_targets_warned=""
_link_targets_usable() {
  [ -L "$LINK_TARGETS" ] || return 0
  if [ -z "$_link_targets_warned" ]; then
    warn "link: $LINK_TARGETS is a symlink - ignoring it, so links from another checkout are backed up"
    _link_targets_warned=1
  fi
  return 1
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
# is still the framework's (_link_owned, the predicate uninstall uses too), is
# unlinked. Any other symlink is left untouched AND stays recorded (manifest and
# pair), so a later uninstall still sees it and its .bak. A real file there (the
# user replaced the link) is left too, and stays recorded while a .bak exists; a
# missing DEST gets its .bak restored. Dropping the entry from the manifest without unlinking the
# stale symlink is what leaves an unmanaged orphan on disk - the shape a dropped
# config/<prog> tree produces: source gone, rule gone, link still there. ROOT
# empty (a fixture, or a caller that does not opt in) disables the prune, so it
# never fires without a repo root to judge containment against. This
# runs ONLY here on the clean finalize path - never in link_manifest_merge, whose
# superset must not drop a still-live link on an interrupted run.
# A pruned link's DEST.bak is restored exactly as uninstall restores it
# (_link_restore_bak): once the entry leaves the manifest, no later uninstall
# would ever see that .bak again. An entry whose unlink or restore did not
# complete stays in the published manifest, so uninstall can still finish it.
# A line _link_under_home refuses is dropped when nothing exists at DEST or
# DEST.bak, and otherwise kept; a kept one makes finalize return 2 AFTER
# publishing, a status of its own so the installer can say what it means
# (see "Manifest keeps an entry the framework may not act on" in
# docs/troubleshooting.md) rather than "could not be created".
link_manifest_finalize() {
  local dest="$1" root="${2-}" tmp old keep d t r prc=0
  [ -n "${LINK_MANIFEST-}" ] || return 0
  tmp="$(mktemp "$dest.XXXXXX")" || return 1
  if ! LC_ALL=C sort -u "$LINK_MANIFEST" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  # A separate file, not $tmp: comm is still reading $tmp while the prune loop
  # runs. It also carries the kept entries on to the targets publish below.
  keep="$(mktemp "$dest.keep.XXXXXX")" || { rm -f -- "$tmp"; return 1; }
  if [ -n "$root" ] && [ -f "$dest" ]; then
    old="$(mktemp "$dest.old.XXXXXX")" || { rm -f -- "$tmp" "$keep"; return 1; }
    LC_ALL=C sort -u "$dest" > "$old"
    # comm -23 OLD NEW = entries in the previous manifest no longer produced.
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      # Reject a non-absolute line FIRST, exactly as uninstall does
      # (lib/uninstall.sh) - a corrupt/legacy relative entry must not resolve
      # against the invocation CWD. Then act only where uninstall may, and
      # unlink only a framework link.
      case "$d" in
        /*) ;;
        *) warn "prune: ignoring non-absolute manifest line: $d"; continue ;;
      esac
      if ! _link_under_home "$d" "$root"; then
        # Nothing at DEST or DEST.bak (lstat only: -L, never followed) means
        # nothing to protect, so the stale line goes; kept, it would fail every
        # later run. Anything there stays recorded and fails the run with its
        # own message until the user sorts it out.
        if [ -e "$d" ] || [ -L "$d" ] || [ -e "$d.bak" ] || [ -L "$d.bak" ]; then
          warn "prune: keeping $d recorded - $LINK_REFUSAL, and something is there"
          printf '%s\n' "$d" >> "$keep"; prc=2
        else
          warn "prune: dropping $d from the manifest - $LINK_REFUSAL, and nothing is there"
        fi
        continue
      fi
      if [ ! -L "$d" ]; then
        if [ -e "$d" ]; then
          # The user replaced the link with a real file: theirs. Its .bak is
          # the pre-framework copy, so the entry stays for uninstall to report.
          if [ -e "$d.bak" ] || [ -L "$d.bak" ]; then
            warn "prune: $d is not our symlink anymore - keeping it and its .bak recorded"
            printf '%s\n' "$d" >> "$keep"
          fi
          continue
        fi
        # DEST is gone (the user deleted the link): put a .bak back, as
        # uninstall would; nothing to restore drops the entry.
        r=0; _link_restore_bak "$d" || r=$?
        [ "$r" -eq 0 ] || printf '%s\n' "$d" >> "$keep"
        continue
      fi
      if ! _link_owned "$d" "$root"; then
        t="$(readlink "$d")"
        warn "prune: $d no longer produced but points outside the repo (-> $t) - leaving it"
        printf '%s\n' "$d" >> "$keep"; continue
      fi
      if ! rm -f -- "$d"; then
        warn "prune: could not remove orphan link $d - keeping it recorded"
        printf '%s\n' "$d" >> "$keep"; continue
      fi
      log "pruned orphan link $d (no longer produced)"
      # A 2 (DEST occupied) needs something to recreate DEST between the rm
      # above and this call - a race, kept as defense rather than trusting it.
      r=0; _link_restore_bak "$d" || r=$?
      case "$r" in
        0) ;;
        2) warn "prune: not restoring $d.bak - something occupies $d"
           printf '%s\n' "$d" >> "$keep" ;;
        *) printf '%s\n' "$d" >> "$keep" ;;
      esac
    done < <(LC_ALL=C comm -23 "$old" "$tmp")
    if [ -s "$keep" ]; then
      LC_ALL=C sort -u "$tmp" "$keep" > "$old" && mv -f -- "$old" "$tmp"
    fi
    rm -f -- "$old"
  fi
  _link_targets_stage finalize "$keep" || { rm -f -- "$tmp" "$keep"; return 1; }
  rm -f -- "$keep"
  mv -f -- "$tmp" "$dest"
  _link_targets_publish
  return "$prc"
}

# The targets file follows every manifest publish, staged before and renamed
# right after it (two files cannot be renamed as one). An interruption between
# the two renames leaves a pair missing or stale, never a pair for a link the
# framework did not make: missing fails closed to a backup, and a stale pair
# matches only a link that still points exactly where the framework linked it.
_link_targets_tmp=""

# _link_targets_stage MODE ARG - write the next targets file to a mktemp sibling.
#   finalize KEEP: this run's pairs, plus the previous pairs of the entries KEEP
#     lists (the ones prune could not finish, which stay in the manifest).
#   merge: this run's pairs, plus every previous pair whose DEST this run did not
#     re-record - a DEST keeps one pair, the one of the link now on disk.
# awk splits on the tab only; FILENAME, not NR==FNR, so an empty first file
# does not swallow the second. File names reach awk through ENVIRON, not -v,
# which would expand backslash escapes in a path. A symlinked previous file is
# read as empty (_link_targets_usable).
_link_targets_stage() {
  local mode="$1" keep="${2-}" prev
  _link_targets_discard
  [ -n "${LINK_TARGETS-}" ] && [ -n "${LINK_TARGETS_SCRATCH-}" ] || return 0
  _link_targets_tmp="$(mktemp "$LINK_TARGETS.XXXXXX")" || return 1
  prev="$LINK_TARGETS"
  { _link_targets_usable && [ -f "$prev" ]; } || prev=/dev/null
  if [ "$mode" = finalize ]; then
    {
      cat -- "$LINK_TARGETS_SCRATCH"
      _lt_keep="$keep" awk -F '\t' \
        'FILENAME == ENVIRON["_lt_keep"] { k[$0] = 1; next } ($1 in k)' "$keep" "$prev"
    } | LC_ALL=C sort -u > "$_link_targets_tmp"
  else
    _lt_cur="$LINK_TARGETS_SCRATCH" awk -F '\t' \
      'FILENAME == ENVIRON["_lt_cur"] { n[$1] = 1; print; next } !($1 in n)' \
      "$LINK_TARGETS_SCRATCH" "$prev" | LC_ALL=C sort -u > "$_link_targets_tmp"
  fi || { _link_targets_discard; return 1; }
}

# _link_targets_publish - rename the staged targets file into place. The rename
# replaces a symlinked $LINK_TARGETS itself, never what it points at. The staged
# file is mktemp's own (created exclusively), so it is not re-checked.
_link_targets_publish() {
  [ -n "$_link_targets_tmp" ] || return 0
  mv -f -- "$_link_targets_tmp" "$LINK_TARGETS"
  _link_targets_tmp=""
}

# _link_targets_discard - drop a staged, unpublished targets file (a re-stage,
# a failed stage, or the installer's exit trap after an interrupt).
_link_targets_discard() {
  [ -n "$_link_targets_tmp" ] && rm -f -- "$_link_targets_tmp"
  _link_targets_tmp=""
}

# _link_restore_bak DEST - put back the DEST.bak link() made, once the framework
# link at DEST is gone. mv renames the .bak itself, so a backed-up symlink (a
# dangling one included, hence the -L) returns with its original target and a
# regular file returns as the file; it MUST NOT become a copy that dereferences
# a link. Returns 0 when restored or when there is no .bak, 2 when something
# occupies DEST (the caller warns in its own words), 1 when the mv failed.
_link_restore_bak() {
  local dest="$1"
  [ -e "$dest.bak" ] || [ -L "$dest.bak" ] || return 0
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    return 2
  fi
  mv -- "$dest.bak" "$dest" || return 1
  log "restored $dest from .bak"
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
  _link_targets_stage merge || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$dest"
  _link_targets_publish
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
      gnupg)         _link_gnupg "$dir" "$root" || rc=1 ;;      # selective
      git)           _link_git "$dir" "$cfg" "$root" || rc=1 ;;  # (write-back)
      rclone|restic) : ;;                                       # secrets
      *)             link "$dir" "$cfg/$prog" "$root" || rc=1 ;; # the convention
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
  local dir="$1" root="$2" name rc=0
  [ -d "$HOME/.gnupg" ] || ( umask 077 && mkdir -p -- "$HOME/.gnupg" )
  for name in gpg.conf gpg-agent.conf; do
    [ -e "$dir/$name" ] || continue
    link "$dir/$name" "$HOME/.gnupg/$name" "$root" || rc=1
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
  # The same containment link() applies: nothing below is written outside $HOME.
  # $gitdir, not $dest: a stale ~/.config/git link into the repo is step (1)'s
  # to convert, so its inside must not be judged before that.
  if ! _link_under_home "$gitdir" "$root"; then
    warn "link: refusing $gitdir - $LINK_REFUSAL"
    return 1
  fi
  # (1) Convert a WHOLE-DIR symlink into the repo (~/.config/git -> repo/config/git),
  #     which would make the tracked config git's global write target: remove ONLY
  #     the link (never its target) so a real dir can hold the local file.
  if [ -L "$gitdir" ]; then
    if _link_owned "$gitdir" "$root"; then
      if rm -f -- "$gitdir"; then
        log "git: converted stale ~/.config/git dir symlink to a real dir"
      else
        warn "git: could not remove the stale ~/.config/git symlink"; return 1
      fi
    else
      target="$(readlink "$gitdir")"
      log "git: leaving a foreign ~/.config/git symlink intact ($gitdir -> $target)"; return 0
    fi
  fi
  mkdir -p -- "$gitdir" || { warn "git: could not create $gitdir"; return 1; }
  # (1b) The global ignore list: git reads $XDG_CONFIG_HOME/git/ignore natively, so
  #      a plain link puts it exactly where git already looks and no
  #      core.excludesfile (an absolute path) is needed. Unlike `config` below, this
  #      file is wholly ours - nothing writes to it - so it is a normal managed link
  #      and IS manifested, which means uninstall removes it.
  if [ -e "$dir/ignore" ]; then
    link "$dir/ignore" "$gitdir/ignore" "$root" || return 1
  fi
  # (2) The config FILE: seed a real local include-file when absent, convert a stale
  #     symlink INTO the repo, and never clobber an existing real (machine-local) file.
  if [ -L "$dest" ]; then
    if _link_owned "$dest" "$root"; then
      rm -f -- "$dest" \
        || { warn "git: could not remove the stale ~/.config/git/config symlink"; return 1; }
      _write_git_local_config "$dest" "$tracked" || return 1
    else
      log "git: leaving a foreign ~/.config/git/config symlink intact"; return 0
    fi
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
    link "$f" "$HOME/.$base" "$root" || rc=1
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
#   leak onto PATH by omission. A host upgrading from an older revision that
#   linked them gets those links pruned as orphans (link_manifest_finalize),
#   since they point into the repo and are no longer produced.
_link_bin_tree() {
  local root="$1" f base rc=0
  [ -d "$root/bin" ] || return 0
  for f in "$root"/bin/*; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue    # admit dangling symlinks too
    base="${f##*/}"
    case "$base" in
      check-patterns | secret-scan | smoke | startup-fork-gate | repo-settings-check) continue ;;   # dev gates
    esac
    link "$f" "$HOME/.local/bin/$base" "$root" || rc=1
  done
  return "$rc"
}
