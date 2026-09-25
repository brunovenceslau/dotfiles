#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# The fork-elimination shims steer VENDORED code at
# runtime (a scoped mv builtin, a hidden `commands` view, a uname function).
# The forkgate proves the ABSENCE of forks; this test proves the shims left the
# LIVE SHELL's semantics intact - the regression class the forkgate cannot see
# (a stranded builtin/function/hide forks nothing, so the gate stays green
# while the operator's interactive shell quietly changes behaviour; measured:
# removing the `-b:mv` disable turns interactive mv into a builtin that cannot
# cross filesystems, and every other gate stays green).
#
# Post-startup contract, asserted through a real hermetic `zsh -i -c`:
#   * `mv` is the REAL command again (not the zsh/files builtin)      [Critical]
#   * `uname` is the real command again (not the loader shim)         [Medium]
#   * `$+commands[who]` == 1 (the `commands` hide was restored)       [High]
#   * compdump + its .zwc were built (the compinit path ran)          [Medium]
#
# The psvar[13] cases are gone with the `pure` prompt: that was pure's own
# user@host cue, and nothing in starship uses psvar. The `commands`-hide
# assertion above stays and is the one that actually mattered here - it is the
# shim whose leak would blind every `(( $+commands[x] ))` guard in the config.
#
# Can-fail proof (the harness's licence to exist): a cp -a copy with the
# `-b:mv` disable REMOVED must be caught by the same introspection - the
# mutation the whole suite previously missed.
#
# Hermetic: scratch HOME/XDG via mktemp + trap; the measured shell is the REAL
# repo config (plugin .zwc refresh lands in the
# repo, gitignored); the mutation case runs against a cp -a copy only.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v zsh >/dev/null 2>&1 || {
  if [ -n "${STRICT:-}" ]; then fail "zsh not found and STRICT set"; fi
  echo "SKIP: zsh not found - startup_state_test needs the measured shell"
  exit 0
}

work="$(mktemp -d "${TMPDIR:-/tmp}/startup_state.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# One introspection line, printed by the measured shell itself after a full
# startup. `whence -w` names the resolution class (command/builtin/function).
probe='print -r -- "mv=${$(whence -w mv)#mv: } uname=${$(whence -w uname)#uname: } who=$+commands[who]"'

# run_probe LABEL ROOT SSH_VALUE -> stdout line; scratch rebuilt per call.
run_probe() {
  label="$1" root="$2" sshv="$3"
  scratch="$work/$label"
  rm -rf "$scratch"
  mkdir -p "$scratch/config/zsh" "$scratch/cache/zsh" "$scratch/state/dotfiles"
  ln -sf "$root/zsh/zshenv" "$scratch/config/zsh/.zshenv"
  ln -sf "$root/zsh/zshrc"  "$scratch/config/zsh/.zshrc"
  : > "$scratch/state/dotfiles/update-check.stamp"   # park the fetch
  if [ -n "$sshv" ]; then
    env SSH_CONNECTION="$sshv" \
      HOME="$scratch" XDG_CONFIG_HOME="$scratch/config" \
      XDG_CACHE_HOME="$scratch/cache" XDG_STATE_HOME="$scratch/state" \
      XDG_DATA_HOME="$scratch/data" ZDOTDIR="$scratch/config/zsh" TERM=dumb \
      zsh -i -c "$probe" 2>"$scratch/stderr"
  else
    env -u SSH_CONNECTION \
      HOME="$scratch" XDG_CONFIG_HOME="$scratch/config" \
      XDG_CACHE_HOME="$scratch/cache" XDG_STATE_HOME="$scratch/state" \
      XDG_DATA_HOME="$scratch/data" ZDOTDIR="$scratch/config/zsh" TERM=dumb \
      zsh -i -c "$probe" 2>"$scratch/stderr"
  fi
}

# --- Local session: every shim unwound, no SSH cue ----------------------------
line="$(run_probe local "$repo_root" "")" || fail "local probe shell failed: $(cat "$work/local/stderr")"
case "$line" in *"mv=command"*)    ;; *) fail "local: mv is not the real command after startup (got: $line) - a stranded zsh/files builtin cannot cross filesystems" ;; esac
case "$line" in *"uname=command"*) ;; *) fail "local: uname is not the real command after startup (got: $line) - the loader shim leaked" ;; esac
case "$line" in *"who=1"*)         ;; *) fail "local: \$+commands[who] != 1 (got: $line) - the commands hide leaked; every (( \$+commands[x] )) guard is now blind" ;; esac
[ -s "$work/local/cache/zsh/zcompdump" ]     || fail "local: compdump was not built - the compinit path did not run"
[ -s "$work/local/cache/zsh/zcompdump.zwc" ] || fail "local: compdump.zwc missing - the byte-compile step regressed"

# --- SSH session: the shims unwind there too ----------------------------------
# Kept as a second, differently-shaped startup: SSH_CONNECTION set changes which
# branches some integrations take, and the shims must unwind on that path as well.
line="$(run_probe ssh "$repo_root" "10.0.0.1 1 10.0.0.2 22")" || fail "ssh probe shell failed: $(cat "$work/ssh/stderr")"
case "$line" in *"mv=command"*) ;; *) fail "ssh: mv is not the real command after startup (got: $line)" ;; esac
case "$line" in *"who=1"*)      ;; *) fail "ssh: \$+commands[who] != 1 (got: $line) - the commands hide leaked" ;; esac

# --- Can-fail proof: the mutation this suite previously missed ----------------
# NOTE the copy dir must NOT share a name with the probe label: run_probe
# rm -rf's "$work/<label>", and a collision deletes the repo copy, leaving
# dangling ZDOTDIR symlinks - zsh then starts a DEFAULT shell whose mv is
# `command`, silently reporting the un-mutated answer (measured; the compdump
# guard below is the sentinel that the mutated zshrc actually ran).
copy="$work/mutantrepo"
cp -a "$repo_root" "$copy"
grep -qF 'zmodload -F zsh/files -b:mv' "$copy/zsh/zshrc" \
  || fail "mutation setup: the -b:mv disable line is gone from zshrc (anchor moved?)"
perl -i -ne 'print unless /zmodload -F zsh\/files -b:mv/' "$copy/zsh/zshrc"
line="$(run_probe mutant "$copy" "")" || fail "mutant probe shell failed: $(cat "$work/mutant/stderr")"
[ -s "$work/mutant/cache/zsh/zcompdump" ] \
  || fail "mutation: the mutated zshrc never ran (no compdump) - the probe measured a default shell, not the mutant"
case "$line" in
  *"mv=builtin"*) ;;  # the harness SEES the planted regression -> it can fail
  *) fail "mutation: removing the -b:mv disable was NOT detected (got: $line) - this test cannot fail and proves nothing" ;;
esac

echo "PASS: startup_state_test (fork-elimination shims unwound: mv/uname real, commands view restored on both a local and an SSH startup, compdump built; -b:mv mutation caught)"
