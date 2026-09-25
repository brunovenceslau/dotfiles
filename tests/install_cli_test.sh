#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# CLI-dispatch tests for install.sh: `--help`/`-h`/`help` print usage and exit 0;
# an unknown command or an unexpected argument warns and exits 2; NONE of these
# write into $HOME (they return before do_link). Hermetic: HOME (and XDG) point
# at a mktemp workspace that must stay empty, proving the no-write contract.
# Then two real installs into further mktemp HOMEs: the pre-XDG history
# migration (copy, mode 600, never overwrite) and the refused-link path (exit 1,
# but the shell integrations are still cached and the submodule heal is
# skipped). Not part of the shellcheck
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

# --- unexpected arguments: exit 2, refused before anything is written --------
# Every arm that takes no arguments rejects one, so a typo such as `--dry-run`
# fails loudly instead of running the real thing (install) or being ignored.
for argv in "install --bogus" "packages --bogus" "link extra" "upgrade --force" "reseed-settings x"; do
  # shellcheck disable=SC2086  # word-split on purpose: argv is a subcommand + one argument
  rc=0; out="$("$installer" $argv 2>&1)" || rc=$?
  [ "$rc" -eq 2 ] || fail "install.sh $argv exited $rc (want 2)"
  printf '%s\n' "$out" | grep -q 'takes no arguments' \
    || fail "install.sh $argv did not say it takes no arguments (got: $out)"
done

# --- the no-write contract: HOME stays completely empty ---------------------
# (no `find -quit`: BSD/macOS find lacks it; -mindepth is portable.)
if find "$HOME" -mindepth 1 | grep -q .; then
  fail "a help/error dispatch wrote into HOME (these paths must be write-free)"
fi

# --- first install: the pre-XDG history migration ---------------------------
# A real install into a second scratch HOME. ~/.zsh_history is COPIED (never
# moved) to $XDG_STATE_HOME/zsh/history, byte-identical and mode 600 under a
# umask 022 that would otherwise leave it 644. A later run with a different
# legacy file never overwrites the live history.
h2="$work/h2"; mkdir -p "$h2"
printf ': 1700000000:0;echo secret-token\nls\n' > "$h2/.zsh_history"
chmod 644 "$h2/.zsh_history"
# The real installs run against a SCRATCH COPY of the tree, never the checkout:
# install.sh resolves its repo root from its own path, so the copy is what gets
# linked, and the copy has no .git, so ensure_submodules is a no-op (no network)
# and harden_plugin_perms touches nothing of the real repo. Only files git
# tracks or would track are copied (--cached --others --exclude-standard), so an
# ignored machine-local file (a `.local` layer, a restic `.env`) never lands in
# $TMPDIR; the plugin submodules are excluded, as the steps under test do not
# need them. tar reads the working tree, so uncommitted edits are included.
tree="$work/tree"; mkdir -p "$tree"
git -C "$repo_root" ls-files -z --cached --others --exclude-standard -- \
    install.sh lib zsh config bin packages ':(exclude)zsh/plugins' \
  | tar -C "$repo_root" --null -T - -cf - | tar -C "$tree" -xf -
[ -f "$tree/install.sh" ] || fail "scratch copy of the tree is empty (git ls-files | tar failed)"
irun() {   # irun HOME [PATH] -> a full `install.sh install` of the copy, output to $work/irun.out
  ( umask 022
    env HOME="$1" XDG_CONFIG_HOME="$1/.config" XDG_CACHE_HOME="$1/.cache" \
      XDG_STATE_HOME="$1/.local/state" PATH="${2:-$PATH}" \
      "$tree/install.sh" install ) > "$work/irun.out" 2>&1
}
irun "$h2" || fail "install into a scratch HOME failed: $(cat "$work/irun.out")"
tree_p="$(cd "$tree" && pwd -P)"
[ "$(readlink "$h2/.zshenv")" = "$tree_p/zsh/zshenv" ] \
  || fail "the install linked something other than the scratch copy: $(readlink "$h2/.zshenv")"
hist="$h2/.local/state/zsh/history"
cmp -s "$h2/.zsh_history" "$hist" || fail "migrated history is not byte-identical to ~/.zsh_history"
[ "$(ls -l "$hist" | cut -c1-10)" = "-rw-------" ] \
  || fail "migrated history is not mode 600: $(ls -l "$hist")"
[ -f "$h2/.zsh_history" ] || fail "the legacy ~/.zsh_history was moved, not copied"
printf 'a different legacy file\n' > "$h2/.zsh_history"
irun "$h2" || fail "re-install failed: $(cat "$work/irun.out")"
cat "$work/irun.out" > "$work/irun.h2.out"
grep -q 'secret-token' "$hist" || fail "a re-run overwrote the live history with the legacy file"

# --- a refused link still leaves a working shell ------------------------------
# A pre-existing real ~/.config/nvim makes one link refuse. The install must exit
# 1, but only AFTER caching the shell integrations: a stub zoxide on PATH must
# still get its cached init, so the user's next shell has its tools.
h3="$work/h3"; mkdir -p "$h3/.config/nvim" "$work/stubbin"
printf '#!/bin/sh\necho "# zoxide init stub"\n' > "$work/stubbin/zoxide"
chmod u+x "$work/stubbin/zoxide"
rc=0; irun "$h3" "$work/stubbin:$PATH" || rc=$?
[ "$rc" -eq 1 ] || fail "install over a real ~/.config/nvim exited $rc (want 1): $(cat "$work/irun.out")"
grep -q 'refusing to replace an existing directory' "$work/irun.out" \
  || fail "the refused link was not reported: $(cat "$work/irun.out")"
[ -s "$h3/.cache/zsh/zoxide-init.zsh" ] \
  || fail "a refused link skipped the shell-integration cache (the degraded-shell bug)"
[ -L "$h3/.zshenv" ] || fail "a refused link blocked the other links"
# ...but the network step waits for a clean link: the submodule heal is skipped,
# with a warning that says so.
grep -q 'skipping plugin submodule init because a link was refused' "$work/irun.out" \
  || fail "a refused link did not skip the submodule init: $(cat "$work/irun.out")"
# A clean install does not print that warning.
if grep -q 'skipping plugin submodule init' "$work/irun.h2.out"; then
  fail "a clean install claimed it skipped the submodule init"
fi

echo "PASS: install_cli_test"
