#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for zsh/fzf.zsh - the two properties that matter: it is active only
# when fzf exists and costs nothing otherwise, and it spawns no subprocess (the
# shell scripts are sourced from static files by directory existence, never
# `fzf --zsh`). This host has fzf/fd in /usr/bin, so the tests build their own
# bin to isolate presence/absence, and use an FZF_SHELL_DIR override pointing at
# fake key-binding scripts. FZF_DEFAULT_COMMAND needs no tty (probed directly);
# the key-bindings are tty-guarded (they raise `can't change option: zle` under
# `zsh -i -c`, which is exactly the smoke's mode), so they are probed under a
# pseudo-tty via `script`. Hermetic mktemp; the real environment is untouched.
# Not on the shellcheck surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ck() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail "$1: got [$2] want [$3]"; fi; }
if ! command -v zsh >/dev/null 2>&1; then
  if [ -n "${STRICT:-}" ]; then fail "zsh not installed and STRICT=1"; fi
  echo "SKIP: zsh unavailable"; exit 0
fi
zsh_bin="$(command -v zsh)"   # absolute - the tests set PATH to a scratch bin

# Env hermeticity: the absence-cases assert FZF_* are UNSET after sourcing, but a
# run inherits the FZF_* exports of the shell that launched it (the developer's
# own env on a local run), which would leak in and fail those cases. `zsh -f`
# skips rc files but does NOT scrub the inherited environment - so clear the vars
# fzf.zsh touches here, once, and every child zsh below starts from a clean slate.
# Case 5 sets FZF_DEFAULT_OPTS explicitly on its own invocation, unaffected by this.
unset FZF_DEFAULT_COMMAND FZF_CTRL_T_COMMAND FZF_ALT_C_COMMAND FZF_DEFAULT_OPTS

work="$(mktemp -d "${TMPDIR:-/tmp}/fzf_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
sbin="$work/bin"; mkdir -p "$sbin"
mkfake() { printf '#!/bin/sh\n' > "$sbin/$1"; chmod +x "$sbin/$1"; }
share="$work/share"; mkdir -p "$share"
printf 'typeset -g _FZF_KB=loaded\n'   > "$share/key-bindings.zsh"
printf 'typeset -g _FZF_COMP=loaded\n' > "$share/completion.zsh"
field() { printf '%s\n' "$1" | tr '|' '\n' | grep "^$2=" | cut -d= -f2-; }

# non-tty probe: FZF_DEFAULT_COMMAND / OPTS need no tty
probe() {
  PATH="$sbin" FZF_SHELL_DIR="$share" ZDOTDIR="$work" "$zsh_bin" -fc "
    source '$repo_root/zsh/fzf.zsh'
    print -r -- \"KB=\${_FZF_KB-unset}|CMD=\${FZF_DEFAULT_COMMAND-unset}|ALTC=\${FZF_ALT_C_COMMAND-unset}|OPTS=\${FZF_DEFAULT_OPTS-unset}\"
  " 2>/dev/null
}
# pty probe: key-bindings need a controlling terminal. A driver file avoids nested
# quoting. Run it under zsh's own zpty module rather than the external `script`:
# `script`'s flag order AND output routing differ across GNU and BSD - on
# macOS/BSD it records the child's output to the typescript FILE, not to its piped
# stdout, so `script … /dev/null | …` captured nothing (the assertion saw empty
# output). zpty is a zsh builtin with identical behavior on Linux and macOS; it
# gives the child a real pty, so fzf.zsh's `[[ -t 0 ]]` guard passes.
kbdriver="$work/kbdriver"
cat > "$kbdriver" <<DRV
export PATH="$sbin" FZF_SHELL_DIR="$share" ZDOTDIR="$work"
"$zsh_bin" -fc 'source "$repo_root/zsh/fzf.zsh"; print -r -- "KB=\${_FZF_KB-unset}|COMP=\${_FZF_COMP-unset}"'
DRV
have_pty=no
"$zsh_bin" -fc 'zmodload zsh/zpty' >/dev/null 2>&1 && have_pty=yes
probe_tty() {
  KBDRIVER="$kbdriver" "$zsh_bin" -fc '
    zmodload zsh/zpty || exit 0
    zpty w sh "$KBDRIVER"
    out=; chunk=
    while zpty -r w chunk; do out+=$chunk; done
    zpty -d w
    printf "%s" "$out"
  ' 2>/dev/null | tr -d '\r'
}

# --- 1. zero cost when fzf is absent ($sbin has fd but no fzf) -----------------
mkfake fd
out="$(probe)"
ck "no fzf -> key-bindings NOT sourced" "$(field "$out" KB)" "unset"
ck "no fzf -> FZF_DEFAULT_COMMAND unset" "$(field "$out" CMD)" "unset"
ck "no fzf -> FZF_DEFAULT_OPTS unset"    "$(field "$out" OPTS)" "unset"

# --- 2. fzf + fd: command set (no tty); key-bindings load under a pty ----------
mkfake fzf
out="$(probe)"
ck "fd present -> fd is the default command" "$(field "$out" CMD)" "fd --type f --hidden --follow --exclude .git"
ck "Alt-C uses --type d (directories)" "$(field "$out" ALTC)" "fd --type d --hidden --follow --exclude .git"
ck "FZF_DEFAULT_OPTS gets a default" "$(field "$out" OPTS)" "--height 40% --layout=reverse --border"
if [ "$have_pty" = yes ]; then
  tout="$(probe_tty)"
  ck "fzf + tty -> key-bindings sourced" "$(field "$tout" KB)" "loaded"
  ck "fzf + tty -> completion sourced"   "$(field "$tout" COMP)" "loaded"
else
  if [ -n "${STRICT:-}" ]; then fail "zsh/zpty module unavailable and STRICT=1"; fi
  echo "  SKIP: zsh/zpty module unavailable - key-bindings load not exercised"
fi

# --- 3. fzf + fdfind (no fd) -------------------------------------------------
rm -f "$sbin/fd"; mkfake fdfind
out="$(probe)"
ck "no fd but fdfind -> fdfind is the command" "$(field "$out" CMD)" "fdfind --type f --hidden --follow --exclude .git"
ck "fdfind Alt-C uses --type d" "$(field "$out" ALTC)" "fdfind --type d --hidden --follow --exclude .git"

# --- 4. fzf but neither fd nor fdfind: no default command (fzf's own walker) ---
rm -f "$sbin/fdfind"
out="$(probe)"
ck "fzf only -> FZF_DEFAULT_COMMAND unset (built-in walker)" "$(field "$out" CMD)" "unset"

# --- 5. a host-provided FZF_DEFAULT_OPTS is preserved, not overwritten ---------
mkfake fd
out="$(PATH="$sbin" FZF_SHELL_DIR="$share" FZF_DEFAULT_OPTS='--custom' ZDOTDIR="$work" \
  "$zsh_bin" -fc "source '$repo_root/zsh/fzf.zsh'; print -r -- \"OPTS=\${FZF_DEFAULT_OPTS}\"" 2>/dev/null)"
ck "existing FZF_DEFAULT_OPTS preserved" "$(field "$out" OPTS)" "--custom"

# --- 6. no `fzf --zsh` subprocess anywhere in CODE -------------
# Strip comments first - the file's header explains why it avoids `fzf --zsh`.
if sed 's/#.*//' "$repo_root/zsh/fzf.zsh" | grep -q 'fzf --zsh\|fzf --bash\|<(fzf'; then
  fail "fzf.zsh uses a subprocess form (fzf --zsh / process substitution) on the startup path"
fi
pass=$((pass + 1))

# --- 7. key-bindings are tty-guarded (the smoke's clean zsh -i -c depends on it)
grep -q '\[\[ -t 0 \]\]' "$repo_root/zsh/fzf.zsh" \
  || fail "fzf.zsh must guard key-bindings on a tty ([[ -t 0 ]]) - else zsh -i -c dirties stderr with 'can't change option: zle'"
pass=$((pass + 1))

echo "PASS: fzf_test ($pass assertions)"
