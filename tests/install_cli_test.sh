#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# CLI-dispatch tests for install.sh: `--help`/`-h`/`help` print usage and exit 0;
# an unknown command warns and exits 2; NONE of these write into $HOME (they
# return before do_link). These are the only install.sh code paths testable
# without a scratch-HOME install - the full install/link flow writes into $HOME
# and is deferred to `make smoke`. Hermetic: HOME (and XDG) point at a mktemp
# workspace that must stay empty, proving the no-write contract that lets these
# paths run without ever touching a real $HOME. Not part of the shellcheck
# surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
installer="$repo_root/install.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/install_cli_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# Pin HOME and every XDG root into the throwaway workspace so nothing can reach
# the real $HOME even if a path unexpectedly tried to write.
export HOME="$work/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" \
       XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME"

# --- help aliases: exit 0 + the usage line ----------------------------------
for arg in --help -h help; do
  rc=0; out="$("$installer" "$arg" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "install.sh $arg exited $rc (want 0)"
  printf '%s\n' "$out" | grep -q 'usage: install.sh' \
    || fail "install.sh $arg did not print the usage line"
done

# --- unknown command: exit 2 + a warning ------------------------------------
rc=0; out="$("$installer" bogus 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "install.sh bogus exited $rc (want 2)"
printf '%s\n' "$out" | grep -q 'unknown command' \
  || fail "install.sh bogus did not warn about the unknown command"

# --- uninstall with an unknown option: exit 2, refused BEFORE any removal ----
# do_uninstall's arg loop completes before uninstall_links runs, so this path is
# write-free too (and must stay so - the usage-error exit code is 2, distinct
# from 1 = a removal that failed; the exit-code fidelity fix in the dispatch).
rc=0; out="$("$installer" uninstall --typo 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "install.sh uninstall --typo exited $rc (want 2)"
printf '%s\n' "$out" | grep -q 'unknown option' \
  || fail "install.sh uninstall --typo did not warn about the unknown option"

# --- the no-write contract: HOME stays completely empty ---------------------
# (no `find -quit`: BSD/macOS find lacks it; -mindepth is portable.)
if find "$HOME" -mindepth 1 | grep -q .; then
  fail "a help/error dispatch wrote into HOME (these paths must be write-free)"
fi

echo "PASS: install_cli_test"
