# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# zsh/functions.zsh - small interactive helpers. Sourced from zshrc.
#
# The two lifecycle commands, dotfiles-uninstall and dotfiles-upgrade, live here as
# thin wrappers over install.sh. Everything here is a convenience run on demand, so
# nothing forks at startup; the bodies do spawn processes, which is fine off the
# startup path - the no-fork rule governs startup, not user-invoked commands. Each
# helper keeps its variables `local`, reports usage and errors to stderr, and
# returns a non-zero status on failure.
# This file sources its own untracked `.local` pair last.

# mkcd DIR - create DIR (and any parents) and cd into it.
mkcd() {
  if [[ $# -ne 1 ]]; then
    print -u2 'usage: mkcd <dir>'
    return 2
  fi
  mkdir -p -- "$1" && cd -- "$1"
}

# up [N] - cd up N directory levels (default 1). `up 3` == `cd ../../..`.
# `target`, not `path`: `path` is zsh's array alias for $PATH, so a `local path`
# scalar would corrupt PATH instead of holding the relative path.
up() {
  local levels="${1:-1}" target='' i
  if [[ $levels != <1-> ]]; then
    print -u2 'up: level must be a positive integer'
    return 2
  fi
  for (( i = 0; i < levels; i++ )); do
    target+='../'
  done
  cd -- "$target"
}

# extract FILE - unpack an archive into the cwd, dispatching on its extension.
# Trusts the archive's member paths (a `../` traversal entry lands where the tool
# puts it) - fine under this repo's single-user model of unpacking your own
# downloads; do not point it at untrusted archives.
extract() {
  if [[ $# -ne 1 ]]; then
    print -u2 'usage: extract <archive>'
    return 2
  fi
  if [[ ! -f $1 ]]; then
    print -u2 "extract: not a file: $1"
    return 2
  fi
  # A leading-dash name (`-foo.zip`) would be parsed as an option by unzip/7z
  # (which have no `--` end-of-options guard); `./`-prefixing a relative such
  # name keeps every tool below treating it as a path. Absolute paths are safe.
  local file="$1"
  [[ $file == -* ]] && file="./$file"
  case $file in
    *.tar.bz2 | *.tbz2) tar -xjf "$file" ;;
    *.tar.gz | *.tgz)   tar -xzf "$file" ;;
    *.tar.xz | *.txz)   tar -xJf "$file" ;;
    *.tar)              tar -xf "$file" ;;
    *.gz)               gunzip "$file" ;;
    *.bz2)              bunzip2 "$file" ;;
    *.xz)               unxz "$file" ;;
    *.zip)              unzip "$file" ;;
    *.7z)               7z x "$file" ;;
    *) print -u2 "extract: unknown archive type: $1"; return 1 ;;
  esac
}

# serve [PORT] - serve the current directory over HTTP on localhost (port 8000).
# Binds 127.0.0.1, never 0.0.0.0: a quick file share must not expose the cwd to
# the whole LAN. PORT is validated as a plain integer and passed after `--` so a
# value like `--bind=0.0.0.0` cannot smuggle a second bind option past the
# hardened localhost bind. Both branches use Python 3's http.server
# (SimpleHTTPServer was Python 2 only, long EOL); the `python` fallback covers
# hosts that ship only an unversioned python3.
# The optional dependency is probed with (( $+commands[x] )), so a
#   host without python gets a clear message instead of a raw "command not found".
serve() {
  local port="${1:-8000}"
  if [[ $port != <1-65535> ]]; then
    print -u2 'serve: port must be an integer 1-65535'
    return 2
  fi
  if (( $+commands[python3] )); then
    python3 -m http.server --bind 127.0.0.1 -- "$port"
  elif (( $+commands[python] )); then
    python -m http.server --bind 127.0.0.1 -- "$port"
  else
    print -u2 'serve: needs python3 on PATH'
    return 1
  fi
}

# gcd [SUBPATH] - cd to the current git repo's root, or to SUBPATH beneath it.
gcd() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    print -u2 'gcd: not inside a git repository'
    return 1
  }
  cd -- "$root${1:+/$1}"
}

# --- Lifecycle (Phase 5) ------------------------------------------------------
# dotfiles-uninstall [--purge] - remove the framework's links (and, with --purge,
# its generated state/cache), driven by the install manifest. A thin wrapper over
# `install.sh uninstall` so the logic lives once, in bash 3.2 (lib/uninstall.sh),
# and is unit-tested there.
dotfiles-uninstall() {
  "$DOTFILES/install.sh" uninstall "$@"
}

# dotfiles-upgrade - fetch, fast-forward the repo, re-link, and recompile stale
# byte-code. A thin wrapper over `install.sh upgrade` so the logic lives once, in
# bash 3.2, and is unit-tested there. The merge is --ff-only: a diverged or
# rewound history is refused rather than reset to.
dotfiles-upgrade() {
  "$DOTFILES/install.sh" upgrade "$@"
}

# --- clipboard toys -----------------------------------------------------------
# One clipboard helper, branching once, so the four callers below stay one-liners.
# macOS has pbcopy; elsewhere try the usual X/Wayland tools and degrade to stdout.
_dotfiles_clip() {
  emulate -L zsh
  local text="$1"
  if (( $+commands[pbcopy] )); then
    print -rn -- "$text" | pbcopy && print -r -- "copied to clipboard"
  elif (( $+commands[wl-copy] )); then
    print -rn -- "$text" | wl-copy && print -r -- "copied to clipboard"
  elif (( $+commands[xclip] )); then
    print -rn -- "$text" | xclip -selection clipboard && print -r -- "copied to clipboard"
  else
    print -r -- "$text"
  fi
}
disappointed() { _dotfiles_clip " ಠ_ಠ " }
flip()         { _dotfiles_clip "（╯°□°）╯ ┻━┻" }
shrug()        { _dotfiles_clip "¯\_(ツ)_/¯" }

# matrix - an awk screensaver. Ctrl-C to stop.
matrix() {
  emulate -L zsh
  (( $+commands[awk] )) || { print -ru2 -- "matrix: awk not found"; return 1 }
  echo -e "\e[1;40m"; clear
  while :; do
    echo "$LINES $COLUMNS $(( RANDOM % COLUMNS )) $(( RANDOM % 72 ))"
    sleep 0.05
  done | awk '{
    letters = "abcdefghijklmnopqrstuvwxyz0123456789@#$%^&*()"
    c = $4
    letter = substr(letters, c, 1)
    a[$3] = 0
    for (x in a) {
      o = a[x]
      a[x] = a[x] + 1
      printf "\033[%s;%sH\033[2;32m%s", o, x, letter
      printf "\033[%s;%sH\033[1;37m%s\033[0;0H", a[x], x, letter
      if (a[x] >= $1) { a[x] = 0 }
    }
  }'
}

# finder - cd to the directory of the frontmost Finder window.
finder() {
  emulate -L zsh
  local dir
  dir=$(osascript -e 'tell app "Finder" to POSIX path of (insertion location as alias)') || return 1
  [[ -n $dir ]] || { print -ru2 -- "finder: no Finder window"; return 1 }
  cd -- "$dir"
}

# --- Go helpers ---------------------------------------------------------------
# Colourize go test output. `grep -E`/GREP_COLORS, not the deprecated
# egrep/GREP_COLOR the original used.
go_test() {
  emulate -L zsh
  (( $+commands[go] )) || { print -ru2 -- "go_test: go not found"; return 1 }
  go test "$@" | sed -E \
    -e "s/^(--- )?PASS/$(print -P '%F{green}')&$(print -P '%f')/" \
    -e "s/^(--- )?SKIP/$(print -P '%F{yellow}')&$(print -P '%f')/" \
    -e "s/^(--- )?FAIL/$(print -P '%F{red}')&$(print -P '%f')/"
  return $pipestatus[1]
}

# go_test_cover - run the tests with coverage and open the HTML report.
go_test_cover() {
  emulate -L zsh
  (( $+commands[go] )) || { print -ru2 -- "go_test_cover: go not found"; return 1 }
  local prof
  prof=$(mktemp "${TMPDIR:-/tmp}/go-cover.XXXXXX") || return 1
  go test -coverprofile="$prof" "$@" && go tool cover -html="$prof"
  local rc=$?
  rm -f -- "$prof"
  return $rc
}

# --- kubectl ------------------------------------------------------------------
# Guarded as a block: without kubectl none of this is defined, and the k* aliases
# never shadow anything. The fzf-driven pickers additionally need fzf.
if (( $+commands[kubectl] )); then
  alias k='kubectl'

  # Context name -> short label, for a prompt or for `kc <alias>`. EMPTY by
  # design: contexts are per-machine and per-employer, so fill this in
  # $ZDOTDIR/functions.zsh.local, never here.
  typeset -gA KUBE_CONTEXT_ALIASES=()

  # kn - pick a namespace with fzf and set it on the current context.
  kn() {
    emulate -L zsh
    (( $+commands[fzf] )) || { print -ru2 -- "kn: fzf not found"; return 1 }
    local ns
    ns=$(kubectl get namespace -o name | sed 's|^namespace/||' | fzf --prompt='namespace> ') || return 1
    [[ -n $ns ]] || return 1
    kubectl config set-context --current --namespace="$ns"
  }

  # kc [alias|context] - switch context. With no argument, pick one with fzf;
  # with an argument, resolve it through KUBE_CONTEXT_ALIASES first.
  kc() {
    emulate -L zsh
    local ctx="${1:-}"
    if [[ -n $ctx ]]; then
      ctx="${KUBE_CONTEXT_ALIASES[$ctx]:-$ctx}"
    else
      (( $+commands[fzf] )) || { print -ru2 -- "kc: fzf not found (or name a context)"; return 1 }
      ctx=$(kubectl config get-contexts -o name | fzf --prompt='context> ') || return 1
    fi
    [[ -n $ctx ]] || return 1
    kubectl config use-context "$ctx"
  }

  # kcn [context] [namespace] - both at once.
  kcn() {
    emulate -L zsh
    kc "${1:-}" || return $?
    kn
  }
fi

# --- zsh completion for the dotfiles-* lifecycle commands ---------------------
#
# Option completion for the dotfiles-* wrappers.
# `dotfiles-uninstall` takes the single flag --purge;
# `dotfiles-upgrade` takes NO arguments by design, so its completion offers
# nothing - registering it SUPPRESSES the default file fallback rather than
# suggesting irrelevant filenames. functions.zsh is sourced AFTER compinit in
# zshrc, so `compdef` is available and only REGISTERS - no startup subprocess.
# No `emulate -L zsh` (completion-hygiene gate).
_dotfiles-uninstall() {
  _arguments -s '--purge[also remove generated state and cache, not just links]'
}

_dotfiles-upgrade() {
  # No arguments by design: complete nothing. `_arguments` with no specs adds no
  # option and no positional, and - because a specific completion is registered -
  # zsh does not fall back to file completion.
  _arguments -s
}

# Guarded on compdef so a source before compinit degrades to no completion
# instead of a startup error (never the zshrc path - functions.zsh loads AFTER
# compinit there).
if (( $+functions[compdef] )); then
  compdef _dotfiles-uninstall dotfiles-uninstall
  compdef _dotfiles-upgrade dotfiles-upgrade
fi

# --- machine-local layer --------------------------------------
# Sourced when present, silent when absent; untracked and never published.
[[ -r $ZDOTDIR/functions.zsh.local ]] && source "$ZDOTDIR/functions.zsh.local"
