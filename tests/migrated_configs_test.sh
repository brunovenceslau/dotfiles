#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Static validation of the configs migrated from the prezto setup, plus the
# starship prompt's cached-init mechanism.
#
# Each assertion here is about a property the migration could silently lose:
#   * nvim/starship/gnupg exist where the link engine will find them
#   * no machine-specific or per-organisation value rode along (a prompt config
#     can carry named cluster contexts; a git config can carry a dead
#     /Users/<old-user> excludesfile)
#   * the global ignore list sits at the path git reads NATIVELY, so no
#     core.excludesfile is needed and cannot go stale
#   * the prompt never forks: zshrc SOURCES a cache, install.sh writes it
#
# Hermetic: reads the repo only. Not part of the shellcheck surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); }

# --- nvim: a plain config/<prog>/ dir, so the convention walker links it -------
[ -d "$repo_root/config/nvim" ] || fail "config/nvim is missing"
[ -s "$repo_root/config/nvim/init.lua" ] || fail "config/nvim/init.lua is missing or empty"
[ -s "$repo_root/config/nvim/lua/config/lazy.lua" ] || fail "config/nvim: the lazy.nvim bootstrap is missing"
ok; ok; ok
# lazy.nvim writes its lockfile INTO the config dir, which is a tracked symlink
# target - so the lockfile must be tracked too, or every plugin sync dirties the
# tree with an untracked file nobody reviews.
git -C "$repo_root" ls-files --error-unmatch config/nvim/lazy-lock.json >/dev/null 2>&1 \
  || fail "config/nvim/lazy-lock.json is untracked - a :Lazy sync would leave an unreviewed file"
ok
# Every plugin spec must be pinned in the lockfile, or `:Lazy sync` silently
# installs a floating HEAD. telescope shipped unpinned in the prezto setup; this
# is the assertion that would have caught it.
for spec in "$repo_root"/config/nvim/lua/plugins/*.lua; do
  [ -e "$spec" ] || continue
  base="$(basename "$spec" .lua)"
  grep -qi "\"$base" "$repo_root/config/nvim/lazy-lock.json" \
    || fail "config/nvim: plugin spec '$base' has no entry in lazy-lock.json (it would install unpinned)"
  ok
done

# --- starship: config present, and free of named cluster contexts -------------
[ -s "$repo_root/config/starship/starship.toml" ] || fail "config/starship/starship.toml is missing"
ok
# A [[kubernetes.contexts]] block names a real cluster, so a committed one is a
# per-organisation value. docker-desktop is the local cluster any machine can
# have and is the only pattern generic enough to track; anything else belongs in
# the untracked layer.
foreign_ctx="$(grep -E '^[[:space:]]*context_pattern[[:space:]]*=' \
  "$repo_root/config/starship/starship.toml" | grep -vF '"docker-desktop"' || true)"
[ -z "$foreign_ctx" ] \
  || fail "config/starship: a kubernetes context names a specific cluster: $foreign_ctx"
ok
# STARSHIP_CONFIG must be exported, because starship's own default is the FILE
# ~/.config/starship.toml, which the config/<prog>/ dir convention cannot produce.
grep -q 'STARSHIP_CONFIG' "$repo_root/zsh/zshenv" \
  || fail "zsh/zshenv does not export STARSHIP_CONFIG - starship would read ~/.config/starship.toml, not ours"
ok

# --- the prompt is sourced from a CACHE, never eval'd from a subprocess -------
# This is the startup-path contract the forkgate enforces; assert the SHAPE here
# too, so a well-meaning "simplification" to the upstream `eval "$(starship init
# zsh)"` idiom fails a fast static test instead of the slow gate.
if grep -qE '\$\(\s*(starship|zoxide)\s+init' "$repo_root/zsh/zshrc"; then
  fail "zsh/zshrc runs '<tool> init' as a subprocess - the startup path must source the cached init"
fi
ok
grep -q 'starship-init.zsh' "$repo_root/zsh/zshrc" \
  || fail "zsh/zshrc does not source the cached starship init"
ok
# The zoxide half of the SAME contract, and the gate that was MISSING: install.sh
# has always generated zoxide-init.zsh beside starship's, but nothing sourced it,
# so `z` did not exist in the shell at all while both this repo's docs and its
# Brewfile advertised it. Not a duplicate of the line above - it is the half whose
# absence let that ship.
grep -q 'zoxide-init.zsh' "$repo_root/zsh/zshrc" \
  || fail "zsh/zshrc does not source the cached zoxide init - \`z\` would not exist"
ok
# canga's completion rides the same contract: `canga completion zsh` is a
# subprocess, so zshrc must source the cache install.sh writes, never run it.
# ANY invocation on a code line, not just `$(...)`: `source <(canga completion
# zsh)` and `canga completion zsh | source` fork just the same, and forkgate
# cannot see them on a host without canga. Comment lines are stripped first,
# because zshrc explains this very contract in prose. POSIX classes, not `\s`,
# so the check means the same thing under BSD grep on macOS.
if grep -vE '^[[:space:]]*#' "$repo_root/zsh/zshrc" \
  | grep -qE '(^|[^[:alnum:]_-])canga[[:space:]]+completion'; then
  fail "zsh/zshrc runs 'canga completion' as a subprocess - the startup path must source the cached script"
fi
ok
grep -q 'canga-completion.zsh' "$repo_root/zsh/zshrc" \
  || fail "zsh/zshrc does not source the cached canga completion"
ok
grep -q '_cache_shell_inits' "$repo_root/install.sh" \
  || fail "install.sh no longer generates the cached shell inits"
ok
# The cache must live where `dotfiles-uninstall --purge` already sweeps, or the
# smoke's no-trace audit fails. $XDG_CACHE_HOME/zsh is such a directory.
grep -q 'cache_dir="\$xdg_cache/zsh"' "$repo_root/install.sh" \
  || fail "install.sh writes the shell-init cache outside \$XDG_CACHE_HOME/zsh (purge would leave a trace)"
ok

# --- gnupg: exactly the two files the link engine's exception links -----------
for f in gpg.conf gpg-agent.conf; do
  [ -s "$repo_root/config/gnupg/$f" ] || fail "config/gnupg/$f is missing or empty"
  ok
done
# The exception links ONLY those two; anything else here would be tracked but
# never installed, which is a silent no-op nobody would notice.
extra="$(find "$repo_root/config/gnupg" -type f ! -name 'gpg.conf' ! -name 'gpg-agent.conf' -print)"
[ -z "$extra" ] || fail "config/gnupg carries files the link engine will never install:$extra"
ok

# --- git: the global ignore list is at git's NATIVE XDG path ------------------
[ -s "$repo_root/config/git/ignore" ] || fail "config/git/ignore is missing"
ok
# core.excludesfile must NOT be set: the whole point of config/git/ignore is that
# git reads $XDG_CONFIG_HOME/git/ignore with no configuration at all, so an
# excludesfile could only ever be an absolute path that rots (it did: the prezto
# setup pointed at a /Users/<old-user> path that had not existed for years, which
# silently disabled the global ignore list entirely).
# Ask GIT, not grep: a bare grep also hits the sentence above explaining WHY the
# key is absent, which is the same false positive the writeback suite's `safe`
# grep used to have.
if git config --file "$repo_root/config/git/config" --get core.excludesfile >/dev/null 2>&1; then
  fail "config/git/config sets core.excludesfile - use the native \$XDG_CONFIG_HOME/git/ignore instead"
fi
ok
grep -q 'link "\$dir/ignore"' "$repo_root/lib/link.sh" \
  || fail "lib/link.sh's git exception no longer links config/git/ignore"
ok

# --- nothing migrated carries a dead absolute home path -----------------------
# The prezto tree was full of one /Users/<old-user> path (an OLD home that no longer
# exists). Any survivor is a silently-broken setting. Detect ANY absolute
# /Users/<name>/ path, not just that one literal: a per-machine username baked
# into a tracked file is the same class of bug regardless of whose name it is,
# and a future migration could just as easily bake in a different one.
for d in config/nvim config/starship config/gnupg config/git zsh/restic.zsh; do
  [ -e "$repo_root/$d" ] || continue
  hit="$(grep -rniE '/Users/[A-Za-z0-9_.-]+' "$repo_root/$d" || true)"
  if [ -n "$hit" ]; then
    fail "$d carries an absolute /Users/<name>/ path - a dead per-machine home: $hit"
  fi
  ok
done

echo "PASS: migrated_configs_test ($pass assertions)"
