#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for lib/os.sh - arch detection helpers.
# Covers the helpers (they exist and are bash+zsh sourceable), the arch
# normalization (aarch64 -> arm64, x86_64 -> amd64) and the fork-free fast path.
# The quadrant and fallback cases set $MACHTYPE inside the child shell, so the
# arm64 branch is exercised on any host, including the linux/x86_64 sandbox this
# suite is often run from. $OSTYPE is still set alongside it: it no longer
# selects anything, but it keeps each case naming the real platform whose
# $MACHTYPE spelling is under test. Not part of the shellcheck surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
oslib="$repo_root/lib/os.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Real-host behaviour ------------------------------------------------------
# shellcheck source=/dev/null
. "$oslib"

case "$(uname -m)" in
  arm64 | aarch64)
    is-arm64 || fail "is-arm64 should be true on $(uname -m)"
    ! is-amd64 || fail "is-amd64 should be false on $(uname -m)" ;;
  x86_64 | amd64)
    is-amd64 || fail "is-amd64 should be true on $(uname -m)"
    ! is-arm64 || fail "is-arm64 should be false on $(uname -m)" ;;
  # exempt: platform/arch skip, not tool-availability
  *) echo "SKIP: unrecognized arch $(uname -m)" ;;
esac

# --- Every $MACHTYPE spelling, host-independent -------------------------------
# Set the builtins inside the child so classification is exercised regardless of
# the real host; asserts the aarch64->arm64 / x86_64->amd64 normalization across
# the full-triplet spellings bash uses and the bare spelling zsh uses.
quad() { # OSTYPE MACHTYPE assertion
  bash -c "OSTYPE='$1'; MACHTYPE='$2'; . '$oslib'; $3" \
    || fail "quadrant OSTYPE=$1 MACHTYPE=$2 : $3"
}
quad darwin23  arm64-apple-darwin23      'is-arm64 && ! is-amd64'
quad darwin23  x86_64-apple-darwin23     'is-amd64 && ! is-arm64'   # Intel mac
quad linux-gnu aarch64-unknown-linux-gnu 'is-arm64 && ! is-amd64'
quad linux-gnu x86_64-pc-linux-gnu       'is-amd64 && ! is-arm64'
quad darwin23  arm64                      'is-arm64 && ! is-amd64'   # bare zsh-style MACHTYPE
quad linux-gnu x86_64                      'is-amd64 && ! is-arm64'

# --- uname fallback branch (empty builtins), host-independent ------------------
# `unset MACHTYPE` forces the `*)` arms, which shell out to `uname -m`. A stub
# uname function answers each spelling, so both arms of both helpers run on every
# host - the CI legs are Darwin and would otherwise never reach this code.
fallback() { # UNAME_M assertion
  bash -c "unset OSTYPE MACHTYPE; uname() { [ \"\$1\" = -m ] && echo '$1'; }; . '$oslib'; $2" \
    || fail "uname fallback with uname -m=$1: $2"
}
fallback arm64   'is-arm64 && ! is-amd64'
fallback aarch64 'is-arm64 && ! is-amd64'
fallback x86_64  'is-amd64 && ! is-arm64'
fallback amd64   'is-amd64 && ! is-arm64'
fallback riscv64 '! is-arm64 && ! is-amd64'

# --- Fork-free fast path ---------------------------------------
# With the builtins populated, a stub uname must never be invoked.
marker="$(mktemp "${TMPDIR:-/tmp}/os_fork.XXXXXX")"
bash -c "
  uname() { echo called >> '$marker'; return 1; }
  OSTYPE='darwin23'; MACHTYPE='arm64-apple-darwin23'
  . '$oslib'
  is-arm64; is-amd64
  [ ! -s '$marker' ]" || fail "fast path forked uname"
rm -f "$marker"

# --- zsh sourceability, arch included, loud skip ---------------
if command -v zsh >/dev/null 2>&1; then
  zsh -c ". '$oslib'; (is-arm64 || is-amd64)" \
    || fail "lib/os.sh not sourceable/functional under zsh"
else
  if [ -n "${STRICT:-}" ]; then fail "zsh not installed and STRICT=1"; fi
  echo "SKIP: zsh not installed - zsh half unverified on this host"
fi

echo "PASS: os_test"
