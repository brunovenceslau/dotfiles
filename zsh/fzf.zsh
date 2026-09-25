# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# zsh/fzf.zsh - fzf integration: active only when the fzf binary
# exists, zero cost otherwise. Loads the STATIC key-binding/completion scripts by
# directory existence - never `source <(fzf --zsh)`, which would fork a subprocess
# on the sacred startup path. Gives Ctrl-R (history), Ctrl-T
# (paste file), Alt-C (cd into dir). fd/fdfind is the file source when present.

(( $+commands[fzf] )) || return 0

# Default file source: fd honors .gitignore, includes hidden files, skips .git,
# follows symlinks. Some distros ship fd as `fdfind`. No tty needed, so
# set it whenever fzf + a finder exist. Guarded, so it is a no-op when neither
# finder is installed - fzf then uses its own built-in walker.
if (( $+commands[fd] )); then
  export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
elif (( $+commands[fdfind] )); then
  export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --follow --exclude .git'
fi
if [[ -n ${FZF_DEFAULT_COMMAND-} ]]; then
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"                    # Ctrl-T: files
  # Alt-C needs a DIRECTORY source, derived by flipping fd's `--type f` to `--type
  # d`. Only when the command actually has `--type f` - for a custom finder (no
  # such flag, or one set in fzf.zsh.local below) leave FZF_ALT_C_COMMAND unset so
  # Alt-C uses fzf's own dir walker instead of silently listing files; a custom
  # finder that wants a dir source should set FZF_ALT_C_COMMAND itself.
  [[ $FZF_DEFAULT_COMMAND == *"--type f"* ]] \
    && export FZF_ALT_C_COMMAND="${FZF_DEFAULT_COMMAND//--type f/--type d}"
fi

# A sane default layout; only set when the host hasn't already (unset or empty),
# overridable in .local.
export FZF_DEFAULT_OPTS="${FZF_DEFAULT_OPTS:---height 40% --layout=reverse --border}"

# Key-bindings + completion drive the ZLE line editor, so load them ONLY with a
# controlling terminal. Under `zsh -i -c` with no tty (the smoke's clean-startup
# probe) the fzf scripts' options save/restore raises `can't change option: zle`
# on stderr; the -t 0 guard skips them there - and they are meaningless without a
# tty anyway (there is no interactive line editor to bind to). Loaded from the
# first location that has them, by directory existence (no fork): an explicit
# $FZF_SHELL_DIR override first (the public knob - set it in .local if your distro
# puts them elsewhere), then Homebrew (arm64 then Intel prefix), then
# common fallbacks. completion.zsh needs compinit, which zshrc ran above.
# The two Homebrew prefixes stay on ONE line: the arm64/Intel PAIR is what marks
# this as prefix detection rather than a hardcode, for a reader and for
# `make check-patterns`, which flags a lone /opt/homebrew.
if [[ -t 0 ]]; then
  () {
    local dir
    for dir in \
      ${FZF_SHELL_DIR:+"$FZF_SHELL_DIR"} \
      /opt/homebrew/opt/fzf/shell /usr/local/opt/fzf/shell \
      /usr/share/doc/fzf/examples \
      /usr/share/fzf ; do
      if [[ -r $dir/key-bindings.zsh ]]; then
        source "$dir/key-bindings.zsh"
        [[ -r $dir/completion.zsh ]] && source "$dir/completion.zsh"
        break
      fi
    done
  }
fi

# machine-local layer: per-host tweaks, sourced when present. An
# `if` (not `[[ … ]] &&`) so this file's exit status is 0 when the .local is absent
# - the common case - mirroring the zshrc's own hook.
if [[ -r $ZDOTDIR/fzf.zsh.local ]]; then
  source "$ZDOTDIR/fzf.zsh.local"
fi
