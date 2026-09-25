#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Zsh completion for the dotfiles-* command surface. Two layers:
#
#   PART 1 (unit, no pty) - the REGISTRATION wiring: source zsh/functions.zsh
#     with a `compdef` STUB that records its calls, and assert the two
#     completions register (`_dotfiles-uninstall dotfiles-uninstall`,
#     `_dotfiles-upgrade dotfiles-upgrade`) and that their completion functions
#     were defined. Hermetic (plain zsh, no `orb`, no completion context).
#     RED-provable: without the compdef block nothing registers and the
#     completion functions are undefined.
#
#   PART 2 (end-to-end via zpty) - the _arguments + compdef wiring: real TAB
#     completion in a child zsh that sources the real file after compinit.
#     RED-provable: without the completion block, `dotfiles-uninstall -<TAB>`
#     offers no `--purge` and `dotfiles-upgrade <TAB>` falls back to offering
#     files.
#
# The function definitions are unconditional, so sourcing the file directly
# defines the completions wherever zsh runs. A test fixture, not an implementing
# site: the lint surface excludes tests/.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
FUNCS="$repo_root/zsh/functions.zsh"
fail() { echo "FAIL: $*" >&2; exit 1; }

if ! command -v zsh >/dev/null 2>&1; then
  if [ -n "${STRICT:-}" ]; then fail "zsh unavailable and STRICT=1 - dotfiles-* completion tests not run"; fi
  echo "SKIP: zsh unavailable - dotfiles-* completion tests not run"; exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/completions_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

pass=0
ok() { pass=$((pass + 1)); echo "  ok: $1"; }
ck_eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (got [$2] want [$3])"; fi; }

# --- PART 1: registration wiring (compdef stub records calls) -----------------
# Stub compdef BEFORE sourcing so `$+functions[compdef]` is true and the guarded
# registration block runs, feeding our recorder. Print each "func cmd" pair, then
# whether each completion function is now defined.
cat > "$work/unit.zsh" <<'ZSH_UNIT_EOF'
#!/usr/bin/env zsh
emulate -L zsh
typeset -ga _REG
compdef() { _REG+=("${(j: :)@}") }
source "${FUNCS:?}"
case $1 in
  reg)  print -rl -- $_REG ;;
  defs) print -r -- "$((${+functions[_dotfiles-uninstall]})) $((${+functions[_dotfiles-upgrade]}))" ;;
esac
ZSH_UNIT_EOF

export FUNCS

# Each completion registers against its command (order-independent membership).
reg_out="$(zsh "$work/unit.zsh" reg)"
for want in "_dotfiles-uninstall dotfiles-uninstall" "_dotfiles-upgrade dotfiles-upgrade"; do
  if grep -qxF -- "$want" <<<"$reg_out"; then
    ok "compdef registers: $want"
  else
    fail "compdef did not register '$want'"$'\n'"$reg_out"
  fi
done

# The completion functions are all defined after sourcing.
defs_out="$(zsh "$work/unit.zsh" defs)"
ck_eq "_dotfiles-uninstall/_dotfiles-upgrade both defined" "$defs_out" "1 1"

# --- PART 2: end-to-end TAB completion via zpty -------------------------------
cat > "$work/zpty.zsh" <<'ZSH_ZPTY_EOF'
#!/usr/bin/env zsh
emulate -L zsh
FUNCS=$1
zmodload zsh/zpty    2>/dev/null || { print -r -- "ZPTY_UNAVAILABLE"; exit 0 }
zmodload zsh/zselect 2>/dev/null || { print -r -- "ZPTY_UNAVAILABLE"; exit 0 }
dir=$(mktemp -d)
# Fixture for the no-file assertion: exactly one plain file with a unique name,
# so a position that must complete nothing is proven to not fall back to files.
: > "$dir/zzfile"
zpty CT 'zsh -f' || { print -r -- "ZPTY_UNAVAILABLE"; exit 0 }
send(){ zpty -w CT "$1"; zselect -t 5 }
drain(){ local x; while zpty -r -t CT x 2>/dev/null; do :; done }
# Type BUF then TAB, collect the terminal output (the completion listing), then
# Ctrl-C to reset. A leading Ctrl-U clears any residue left on the line editor.
capture(){
  local buf="$1" out="" c i
  zpty -w -n CT $'\C-u'
  zselect -t 2; drain
  zpty -w -n CT "$buf"$'\t'
  for (( i=0; i<100; i++ )); do
    while zpty -r -t CT c 2>/dev/null; do out+=$c; done
    zselect -t 3
  done
  zpty -w -n CT $'\C-c'
  zselect -t 3; drain
  print -r -- "$out"
}
expect_in(){     # label buffer literal-pattern (retried; tolerates pty timing)
  local out n
  for (( n=0; n<6; n++ )); do
    out="$(capture "$2")"
    if grep -qF -- "$3" <<<"$out"; then print -r -- "CASE $1 PASS"; return; fi
  done
  print -r -- "CASE $1 FAIL"
}
expect_absent(){ # label buffer negative-pattern - the token must NOT be offered
  # Anti-vacuity: an empty/timing-truncated capture trivially lacks the negative
  # token and would PASS for the wrong reason. Require the typed buffer to have
  # ROUND-TRIPPED (the pty echoes it) first - proof the line was actually entered
  # and completion ran - before ruling the token absent. Retried like expect_in so
  # a slow leg gets the same tolerance; a capture that never echoes fails closed.
  local out n
  for (( n=0; n<6; n++ )); do
    out="$(capture "$2")"
    if grep -qF -- "${2% }" <<<"$out"; then
      if grep -qF -- "$3" <<<"$out"; then print -r -- "CASE $1 FAIL"; else print -r -- "CASE $1 PASS"; fi
      return
    fi
  done
  print -r -- "CASE $1 FAIL"
}
send "PS1='R> '; RPS1=''"
send "autoload -Uz compinit; compinit -u -d $dir/zwc"
# cwd holds exactly one file (zzfile), so a file fallback is observable.
send "cd $dir"
send "source $FUNCS 2>/dev/null || true"
drain
expect_in     uninstall_purge "dotfiles-uninstall -" "--purge" # option completion
expect_absent upgrade_nopurge "dotfiles-upgrade -" "--purge" # upgrade has no flags: --purge is uninstall's (scoping)
expect_absent upgrade_nofile "dotfiles-upgrade "   "zzfile"     # empty _arguments suppresses the default file fallback (anti-vacuous)
zpty -d CT
ZSH_ZPTY_EOF

zpty_out="$(zsh "$work/zpty.zsh" "$FUNCS" || true)"
if grep -q ZPTY_UNAVAILABLE <<<"$zpty_out"; then
  if [ -n "${STRICT:-}" ]; then fail "zsh/zpty unavailable and STRICT=1 - dotfiles-* completion e2e not run"; fi
  echo "SKIP: zsh/zpty unavailable - dotfiles-* completion end-to-end (PART 2) not run"
else
  ck_case() {   # label human-description
    if grep -qx "CASE $1 PASS" <<<"$zpty_out"; then
      ok "$2"
    else
      fail "$2 (zpty case '$1' did not PASS)"$'\n'"$zpty_out"
    fi
  }
  ck_case uninstall_purge "dotfiles-uninstall <TAB> offers --purge"
  ck_case upgrade_nopurge "dotfiles-upgrade <TAB> offers NO --purge (scoped away from uninstall)"
  ck_case upgrade_nofile  "dotfiles-upgrade <TAB> offers NO file (empty _arguments suppresses fallback)"
fi

echo "PASS: completions_test ($pass assertions)"
