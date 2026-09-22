# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# lib/packages.sh - install packages from the tracked manifest.
#
# Sourced by install.sh's `packages` subcommand. Installs via `brew bundle` over
# packages/Brewfile (+ Brewfile.local); macOS is the only target, so there is no
# OS dispatch here. The caller owns shell options and MUST define log()/warn().
#
# Bash 3.2 compatible (no associative arrays, no mapfile, no
#   ${var,,}). shellcheck shell=bash
# shellcheck shell=bash
# shellcheck disable=SC2329

# packages_install - brew bundle, then install gh CLI extensions.
packages_install() {
  local rc=0
  _packages_brew || rc=1
  # Gh CLI extensions, AFTER gh is installed by the brew step above.
  # Best-effort - it never flips rc - because a missing dev extension must not
  # fail the whole package install.
  _packages_gh_extensions
  return "$rc"
}

# _packages_gh_ext_list FILE... - emit one VALID `owner/repo <pin>` per line from
# the given manifests (first two fields), ignoring blanks and # comments. The pin
# is a reviewed commit SHA (40 hex) or a `vX.Y.Z` release tag. A
# security filter, hardened for this call site: the UNTRACKED
# gh-extensions.local.txt reaches `gh extension install --pin <pin> -- <owner/repo>`,
# so a line must satisfy TWO guards or it is dropped -
#   1. `owner/repo` ANCHORED to a leading [A-Za-z0-9] on BOTH sides, so it cannot
#      begin with a dash (a flag like `--force`/`-x`), a dot (`./evil`, or the bare
#      `.` gh treats as a local-dir install), or a slash (`/tmp/x` absolute path);
#      `:` (URLs) and `*` (globs) are outside the class and never match; and
#   2. a well-formed `pin` - so an UNPINNED line (`owner/repo` alone) is refused,
#      never installing a floating latest.
# `awk '{print $1,$2}'` keeps only the first two fields (a whitespace-split third
# token cannot ride along). LC_ALL=C so the classes are not locale-widened.
_packages_gh_ext_list() {
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    tr -d '\r' < "$f" | sed 's/#.*//' | awk 'NF { print $1, $2 }'
  done | LC_ALL=C sort -u \
       | LC_ALL=C grep -E '^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]* ([0-9a-f]{40}|v[0-9]+\.[0-9]+\.[0-9]+)$'
}

# _packages_gh_extensions - install the tracked gh CLI extensions
# (packages/gh-extensions.txt + the untracked .local) idempotently. Guarded on gh
# being present (it is installed by the brew step, but a host without it just
# skips), and best-effort: an install failure warns and the function still returns
# 0, so a flaky network never fails `install.sh packages`.
_packages_gh_extensions() {
  command -v gh >/dev/null 2>&1 || { log "packages: gh not on PATH - skipping gh extensions"; return 0; }
  local exts installed repo pin
  exts="$(_packages_gh_ext_list "$DOTFILES/packages/gh-extensions.txt" "$DOTFILES/packages/gh-extensions.local.txt")"
  [ -n "$exts" ] || return 0
  installed="$(gh extension list 2>/dev/null || true)"
  # Each line is `owner/repo <pin>` (validated). Split on the single space, then
  # install PINNED with a `--` end-of-options belt so even a would-be `-`-leading
  # owner (already blocked by the validator) can never be read as a gh flag.
  while IFS=' ' read -r repo pin; do
    [ -n "$repo" ] || continue
    if printf '%s\n' "$installed" | grep -qF -- "$repo"; then
      log "packages: gh extension already installed: $repo"
    else
      log "packages: installing gh extension: $repo (pinned $pin)"
      gh extension install --pin "$pin" -- "$repo" \
        || warn "packages: gh extension install failed (non-fatal): $repo"
    fi
  done <<EOF
$exts
EOF
  return 0
}

# _packages_brew - brew bundle the tracked Brewfile, then the
# untracked machine-local one. if Homebrew is absent,
# print the OFFICIAL install method and stop - never run a remote curl-into-shell
# bootstrap on the user's behalf. no `sudo` anywhere on this path -
# Homebrew is user-scoped (the signposted-sudo apt path was withdrawn 2026-09-13).
_packages_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    warn "packages: Homebrew is not installed."
    warn "packages: install it via the official method at https://brew.sh, then re-run 'install.sh packages'."
    warn "packages: this installer will NOT run a remote bootstrap script for you."
    return 1
  fi
  local rc=0
  log "packages: brew bundle from packages/Brewfile"
  brew bundle --file "$DOTFILES/packages/Brewfile" || rc=1
  if [ -f "$DOTFILES/packages/Brewfile.local" ]; then
    log "packages: brew bundle from packages/Brewfile.local (machine-local)"
    brew bundle --file "$DOTFILES/packages/Brewfile.local" || rc=1
  fi
  return "$rc"
}

