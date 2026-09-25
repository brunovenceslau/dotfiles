# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# lib/os.sh - shared architecture detection helpers.
#
# Provides is-arm64 / is-amd64, and is sourceable from both bash 3.2
#   and zsh (POSIX-only syntax, no arrays). There is deliberately no OS helper:
#   macOS is the only target, so every call site that used to ask was guarding
#   against an OS this framework does not run on, and those branches are now
#   unconditional rather than conditional on a check that could only ever be
#   true here.
# Architecture is normalized from the machine type
#   (aarch64 -> arm64, x86_64 -> amd64), so is-amd64 is true on an Intel mac.
#   These helpers are the single sanctioned site for arch detection - all arch
#   branching MUST go through them, never an ad-hoc `uname -m`.
# The fast path reads the $MACHTYPE shell builtin, which bash and
#   zsh both populate with no fork, so the helpers are safe to call on the
#   interactive startup path. `uname` is only a fallback for exotic shells that
#   leave it empty.
# Bash 3.2 compatible (no associative arrays, no mapfile,
#   no ${var,,}).
#
# This file is sourced, not executed: no shebang, no `set -e`. The directives
# below pick the lint dialect (bash allows the hyphenated helper names this
# file uses and that zsh also accepts) and silence SC2329 - the
# helpers are a sourced library, invoked by other files, not called here.
# shellcheck shell=bash
# shellcheck disable=SC2329

# $MACHTYPE begins with the CPU on both shells - "x86_64-pc-linux-gnu" (bash) or
# a bare "x86_64"/"arm64" (zsh) - so a glob `case` on its prefix classifies the
# arch without a fork. `${MACHTYPE-}` keeps it safe even under `set -u`; `uname`
# is only the fallback when the builtin is empty.
is-arm64() {
  case "${MACHTYPE-}" in
    arm64* | aarch64*) return 0 ;;
    x86_64* | amd64*)  return 1 ;;
    *) case "$(uname -m)" in arm64 | aarch64) return 0 ;; *) return 1 ;; esac ;;
  esac
}

is-amd64() {
  case "${MACHTYPE-}" in
    x86_64* | amd64*)  return 0 ;;
    arm64* | aarch64*) return 1 ;;
    *) case "$(uname -m)" in x86_64 | amd64) return 0 ;; *) return 1 ;; esac ;;
  esac
}
