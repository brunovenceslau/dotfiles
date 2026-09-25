#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# The zsh/zshenv variable contract, as docs/shell-reference.md#environment-variables
# states it:
#   * a pre-set EDITOR, VISUAL, PAGER, LANG, LESS, LESSOPEN, BROWSER and XDG_*
#     value wins over the framework default;
#   * ZDOTDIR, DOTFILES, STARSHIP_CONFIG, STARSHIP_CACHE, HOMEBREW_NO_ANALYTICS
#     and (when ~/go exists) GOPATH are always overwritten;
#   * EDITOR / VISUAL / LESSOPEN are resolved against the FINAL interactive PATH.
#     zshenv runs before zshrc prepends the Homebrew prefix and ~/.local/bin, so
#     an nvim reachable only there used to leave EDITOR=vim for the whole
#     session (measured on a GUI-launched Apple Silicon terminal). The
#     interactive case below reproduces that with an nvim that lives only in the
#     scratch ~/.local/bin and a PATH that does not contain it.
#
# Hermetic: `env -i` with a scratch HOME and an EMPTY PATH directory, so no tool
# on the tester's machine can leak into the answer. zshrc is fork-free, so an
# empty PATH is enough for a full `zsh -i` startup.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ck() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail "$1: got [$2] want [$3]"; fi; }

if ! command -v zsh >/dev/null 2>&1; then
  if [ -n "${STRICT:-}" ]; then fail "zsh not installed and STRICT=1"; fi
  echo "SKIP: zshenv_contract_test (zsh not installed; enforced in CI)"
  exit 0
fi
zsh_bin="$(command -v zsh)"

work="$(mktemp -d "${TMPDIR:-/tmp}/zshenv_contract.XXXXXX")"
trap 'rm -rf "$work"' EXIT
empty="$work/emptybin"; mkdir -p "$empty"

# --- 1. Defaults with nothing pre-set (non-interactive) -----------------------
h1="$work/h1"; mkdir -p "$h1/go/bin"
out="$(env -i HOME="$h1" PATH="$empty" "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"\$EDITOR|\$VISUAL|\$PAGER|\$LESS|\${LESSOPEN-unset}|\$GOPATH|\$HOMEBREW_NO_ANALYTICS\"
  print -r -- \"\${+functions[_dotfiles_tool_defaults]}\${+_dotfiles_own_editor}\"")"
ck "defaults: EDITOR|VISUAL|PAGER|LESS|LESSOPEN|GOPATH|HOMEBREW_NO_ANALYTICS" \
  "$(printf '%s\n' "$out" | sed -n 1p)" "vim|vim|less|-g -i -M -R -w|unset|$h1/go|1"
ck "non-interactive shell keeps none of the defaulting machinery" \
  "$(printf '%s\n' "$out" | sed -n 2p)" "00"

# --- 2. Honored: a pre-set value wins ------------------------------------------
out="$(env -i HOME="$h1" PATH="$empty" EDITOR=nano VISUAL=code PAGER=more LANG=C \
  LESS=-X LESSOPEN='|x %s' BROWSER=firefox XDG_CONFIG_HOME="$work/cfg" \
  "$zsh_bin" -f -c "source '$repo_root/zsh/zshenv'
  print -r -- \"\$EDITOR|\$VISUAL|\$PAGER|\$LANG|\$LESS|\$LESSOPEN|\$BROWSER|\$XDG_CONFIG_HOME\"")"
ck "honored: pre-set values survive" "$out" "nano|code|more|C|-X||x %s|firefox|$work/cfg"
# VISUAL follows a pre-set EDITOR when VISUAL itself is unset.
out="$(env -i HOME="$h1" PATH="$empty" EDITOR=nano "$zsh_bin" -f -c \
  "source '$repo_root/zsh/zshenv'; print -r -- \"\$VISUAL\"")"
ck "VISUAL defaults to a pre-set EDITOR" "$out" "nano"

# --- 3. Overwritten: the framework's value always wins -------------------------
out="$(env -i HOME="$h1" PATH="$empty" ZDOTDIR=/nope DOTFILES=/nope STARSHIP_CONFIG=/nope \
  STARSHIP_CACHE=/nope HOMEBREW_NO_ANALYTICS=0 GOPATH=/nope "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  print -r -- \"\$ZDOTDIR|\$DOTFILES|\$STARSHIP_CONFIG|\$STARSHIP_CACHE|\$HOMEBREW_NO_ANALYTICS|\$GOPATH\"")"
ck "overwritten: ZDOTDIR|DOTFILES|STARSHIP_*|HOMEBREW_NO_ANALYTICS|GOPATH" "$out" \
  "$h1/.config/zsh|$repo_root|$h1/.config/starship/starship.toml|$h1/.cache/zsh/starship|1|$h1/go"
# GOPATH is only touched when ~/go exists.
h0="$work/h0"; mkdir -p "$h0"
out="$(env -i HOME="$h0" PATH="$empty" GOPATH=/mine "$zsh_bin" -f -c \
  "source '$repo_root/zsh/zshenv'; print -r -- \"\$GOPATH\"")"
ck "GOPATH left alone without ~/go" "$out" "/mine"

# --- 4. Interactive: resolved against the FINAL PATH ---------------------------
# nvim and lesspipe.sh exist ONLY in the scratch ~/.local/bin, which zshrc
# prepends; the inherited PATH is an empty directory.
h2="$work/h2"
mkdir -p "$h2/.local/bin" "$h2/.config/zsh" "$h2/.cache/zsh" "$h2/.local/state/dotfiles"
for t in nvim lesspipe.sh; do printf '#!/bin/sh\n' > "$h2/.local/bin/$t"; chmod u+x "$h2/.local/bin/$t"; done
ln -s "$repo_root/zsh/zshenv" "$h2/.zshenv"
ln -s "$repo_root/zsh/zshrc" "$h2/.config/zsh/.zshrc"
: > "$h2/.local/state/dotfiles/update-check.stamp"   # park the background fetch
probe='print -r -- "$EDITOR|$VISUAL|${LESSOPEN-unset}|${+functions[_dotfiles_tool_defaults]}${+_dotfiles_own_editor}"'
out="$(env -i HOME="$h2" PATH="$empty" TERM=dumb "$zsh_bin" -i -c "$probe" 2>"$work/i.err")" \
  || fail "interactive probe failed: $(cat "$work/i.err")"
ck "interactive: nvim reachable only via zshrc's PATH -> EDITOR/VISUAL=nvim, LESSOPEN set, machinery gone" \
  "$out" "nvim|nvim|| $h2/.local/bin/lesspipe.sh %s 2>&-|00"
# The second pass never rewrites a value the environment chose.
out="$(env -i HOME="$h2" PATH="$empty" TERM=dumb EDITOR=nano LESSOPEN='|mine %s' \
  "$zsh_bin" -i -c "$probe" 2>"$work/i2.err")" || fail "interactive preset probe failed: $(cat "$work/i2.err")"
ck "interactive: pre-set EDITOR/LESSOPEN survive the second pass" "$out" "nano|nano||mine %s|00"

echo "PASS: zshenv_contract_test ($pass assertions)"
