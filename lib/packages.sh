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
#
# Idempotent by NAME AND PIN. The installed version is read from `gh extension
# list` (tab-separated when not on a terminal: name, owner/repo, version) and
# matched on the EXACT repo field - a substring match would report owner/gh-foo
# installed when only owner/gh-foobar is. A pin bump in the manifest must reach
# hosts that already carry the extension, and `gh extension upgrade` skips pinned
# extensions, so a version that differs from the pin is removed and reinstalled
# at the pin. gh prints a git extension's commit as its first 8 characters, so a
# 40-hex pin also matches on that prefix.
_packages_gh_extensions() {
  command -v gh >/dev/null 2>&1 || { log "packages: gh not on PATH - skipping gh extensions"; return 0; }
  local exts installed repo pin cur
  exts="$(_packages_gh_ext_list "$DOTFILES/packages/gh-extensions.txt" "$DOTFILES/packages/gh-extensions.local.txt")"
  [ -n "$exts" ] || return 0
  installed="$(gh extension list 2>/dev/null || true)"
  # Each line is `owner/repo <pin>` (validated). Split on the single space, then
  # install PINNED with a `--` end-of-options belt so even a would-be `-`-leading
  # owner (already blocked by the validator) can never be read as a gh flag.
  while IFS=' ' read -r repo pin; do
    [ -n "$repo" ] || continue
    # "-" marks "not installed"; an installed extension with no version prints "".
    # NO pipe and NO awk `exit` here: install.sh runs under pipefail, and a
    # reader that stops at the first match leaves a `printf | awk` writer to hit
    # a closed pipe on the next line (SIGPIPE, or "printf: write error: Broken
    # pipe" where SIGPIPE is ignored) - timing- and awk-dependent (Linux mawk
    # happens to drain its input first). The here-string has no writer process.
    cur="$(awk -F '\t' -v r="$repo" '$2 == r && !found { print $3; found = 1 } END { if (!found) print "-" }' <<<"$installed")"
    if [ "$cur" = "$pin" ] || { [ "${#pin}" -eq 40 ] && [ "$cur" = "$(printf '%s' "$pin" | cut -c1-8)" ]; }; then
      log "packages: gh extension already installed at its pin: $repo ($pin)"
      continue
    fi
    if [ "$cur" = "-" ]; then
      log "packages: installing gh extension: $repo (pinned $pin)"
      gh extension install --pin "$pin" -- "$repo" \
        || warn "packages: gh extension install failed (non-fatal): $repo - retry: gh extension install --pin $pin -- $repo"
      continue
    fi
    # A re-pin must remove first (gh refuses to install over an installed
    # extension, and `upgrade` ignores pins), so a failed install would leave the
    # host WITHOUT the extension. Guard both ends: remove only once the new pin is
    # confirmed to exist upstream, and if the install still fails, put the
    # previous version back and print the exact command to retry.
    if ! _packages_gh_pin_exists "$repo" "$pin"; then
      warn "packages: gh extension $repo: pin $pin not confirmed upstream (offline, gh not authenticated - try 'gh auth status' - or a bad pin) - left at ${cur:-its current version}"
      continue
    fi
    log "packages: gh extension $repo is at ${cur:-an unknown version}, re-pinning to $pin"
    # Removed by its name, which gh derives from the repo's last component.
    gh extension remove -- "${repo##*/}" \
      || { warn "packages: gh extension remove failed (non-fatal): $repo - left at ${cur:-its current version}"; continue; }
    if ! gh extension install --pin "$pin" -- "$repo"; then
      warn "packages: gh extension install failed (non-fatal): $repo at $pin"
      if [ -n "$cur" ] && gh extension install --pin "$cur" -- "$repo"; then
        warn "packages:   restored the previous version $cur"
      else
        warn "packages:   $repo is NOT installed now"
      fi
      warn "packages:   retry: gh extension remove ${repo##*/}; gh extension install --pin $pin -- $repo"
    fi
  done <<EOF
$exts
EOF
  return 0
}

# _packages_gh_pin_exists REPO PIN - whether PIN resolves upstream: a vX.Y.Z pin
# as a release (gh installs a binary extension from its release assets), a
# 40-hex pin as a commit. One API call; a network failure reads as "no", which
# is the safe answer for the caller (it then leaves the installed version alone).
_packages_gh_pin_exists() {
  local repo="$1" pin="$2"
  case "$pin" in
    v*) gh api "repos/$repo/releases/tags/$pin" >/dev/null 2>&1 ;;
    *)  gh api "repos/$repo/commits/$pin" >/dev/null 2>&1 ;;
  esac
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

