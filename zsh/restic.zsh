# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# zsh/restic.zsh - restic wrappers that resolve their credentials at call time.
#
# The whole point: a restic repository's env file names its secrets by REFERENCE
# (`pass://…`), never by value, and the reference is resolved by a secret manager
# in the child process only. Nothing is written to disk in the clear and nothing
# is exported into this shell.
#
# The env files live in $XDG_CONFIG_HOME/restic (config/restic in the repo, which
# is NEVER linked - see lib/link.sh's exceptions table). The repo tracks only
# README.md and the *.example templates; the real files are untracked and local.
#
# Both wrappers are guarded on restic itself, so a host without it defines
# nothing and pays nothing at startup.
# This file sources its own untracked `.local` pair last.

_restic_env_dir() { print -r -- "${XDG_CONFIG_HOME:-$HOME/.config}/restic" }

# _restic_repos - the repo names a completion offers: every *.env in the env dir,
# basename without the extension. (N) is a null glob so an empty or missing dir
# yields nothing instead of an error; :t takes the tail, :r drops the extension.
_restic_repos() {
  local dir; dir=$(_restic_env_dir)
  local -a repos; repos=( "$dir"/*.env(N:t:r) )
  compadd "$@" -a repos
}

# _restic_run RUNNER NAME ARGS... - shared body. RUNNER is the secret-manager
# command that resolves the pass:// references and execs restic with them in its
# environment.
_restic_run() {
  emulate -L zsh
  local runner="${1:?}" repo="${2:-}"
  shift 2 2>/dev/null || { print -ru2 -- "usage: ${runner}-backed wrapper <repo> [restic args...]"; return 2 }
  if [[ -z $repo ]]; then
    print -ru2 -- "usage: <wrapper> <repo> [restic args...]"
    print -ru2 -- "available: ${$(_restic_env_dir)}/*.env"
    return 2
  fi
  local env_file="$(_restic_env_dir)/${repo}.env"
  if [[ ! -f $env_file ]]; then
    print -ru2 -- "restic: no such repo config: $env_file"
    return 1
  fi
  "$runner" run --env-file "$env_file" -- restic "$@"
}

if (( $+commands[restic] )); then
  # pass-cli is the current secret runner.
  restic-pass-cli() {
    (( $+commands[pass-cli] )) || { print -ru2 -- "restic-pass-cli: pass-cli not found"; return 1 }
    _restic_run pass-cli "$@"
  }
  # op (1Password CLI) is the older one, kept because some repos are still
  # reachable only through it.
  restic-op() {
    (( $+commands[op] )) || { print -ru2 -- "restic-op: op not found"; return 1 }
    _restic_run op "$@"
  }

  # Register completions only when compdef exists - a source before compinit then
  # degrades to no completion instead of a startup error.
  if (( $+functions[compdef] )); then
    compdef _restic_repos restic-pass-cli
    compdef _restic_repos restic-op
  fi
fi

# --- machine-local layer ------------------------------------------------------
[[ -r $ZDOTDIR/restic.zsh.local ]] && source "$ZDOTDIR/restic.zsh.local"
