#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Post-startup contract for the file-NAVIGATION layer restored from the prezto
# setup (its `completion`, `directory`, `utility` and `syntax-highlighting`
# modules). Static greps cannot prove any of it: a zstyle can be present and
# still resolve to nothing (the `-e` list-colors reads $LS_COLORS, which a LATER
# file exports), an alias can be defined and dead (the `d` / 1..9 pair needs
# AUTO_PUSHD), and a cached init can be generated and never sourced - which is
# exactly the defect this suite was written for:
#
#   install.sh's _cache_shell_inits has always written zoxide-init.zsh beside
#   starship's, but zshrc sourced only starship's, so `z` did not exist in the
#   shell at all while docs/architecture.md and packages/Brewfile both
#   advertised it. Every gate stayed green: nothing measured the LIVE shell.
#
# So everything below is asserted through a real hermetic `zsh -i -c` against the
# repo's own zshenv/zshrc, and the suite carries a can-fail proof: a cp -a copy
# with the zoxide source block REMOVED must be caught by the same probe.
#
# Hermetic: scratch HOME/XDG via mktemp + trap, update sentinel parked so the
# sanctioned detached fetch never fires. The real $HOME is never touched, so this
# needs no scratch-HOME consent.
# shellcheck disable=SC2016  # $probe is zsh source for the MEASURED shell: it is
#   deliberately single-quoted so THIS shell never expands it.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ok: $1"; }

command -v zsh >/dev/null 2>&1 || {
  if [ -n "${STRICT:-}" ]; then fail "zsh not found and STRICT set (nothing was measured)"; fi
  echo "SKIP: zsh not found - navigation_state_test needs the measured shell"
  exit 0
}

work="$(mktemp -d "${TMPDIR:-/tmp}/navigation_state.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# f-sy-h lives in a SHA-pinned submodule; with it uninitialized the loader skips
# it and there is no style array to assert against. Detect that up front so the
# path-highlight case is a declared skip, never a silent pass.
fsyh="$repo_root/zsh/plugins/fast-syntax-highlighting/fast-highlight"
if [ -r "$fsyh" ]; then have_fsyh=1; else have_fsyh=0; fi

# One introspection line, printed by the measured shell after a full startup.
# `[[ -o opt ]]` (a builtin test) rather than $options, and `zstyle -a` rather
# than a grep - an `-e` style is EVALUATED on lookup, so a resolved-to-empty
# list-colors reads as 0 here and a static grep would have missed it.
# The f-sy-h lookups MUST be gated: with f-sy-h not loaded FAST_HIGHLIGHT_STYLES
# is undeclared, so `[path]` is a NUMERIC subscript, zsh evaluates `path` as math
# against $path (a scratch-HOME path) and the probe dies on "bad math
# expression". zshrc guards the same constraint with `(( $+... ))`; this check
# is deliberately STRICTER (the parameter must be an association), so a stray
# scalar or array of that name reads as unloaded instead of misparsing - do not
# weaken it to match zshrc.
probe='
o() { [[ -o $1 ]] && print -n "$1=on " || print -n "$1=off " }
o autopushd; o pushdignoredups; o pushdsilent; o cdablevars
o completeinword; o alwaystoend; o pathdirs
typeset -a _lc _comp _ml
zstyle -a ":completion:*:default" list-colors _lc
zstyle -a ":completion:*" completer _comp
zstyle -a ":completion:*" matcher-list _ml
print -n "listcolors=$#_lc approximate=${${_comp[(r)_approximate]}:+yes} matchers=$#_ml "
print -n "lscolors=${#LS_COLORS} "
if [[ ${(t)FAST_HIGHLIGHT_STYLES} == association* ]]; then
  print -n "pathstyle=${FAST_HIGHLIGHT_STYLES[path]:-none} "
  print -n "pathdirstyle=${FAST_HIGHLIGHT_STYLES[path-to-dir]:-none} "
else
  print -n "pathstyle=unloaded pathdirstyle=unloaded "
fi
print -n "aliasd=$+aliases[d] alias1=$+aliases[1] aliaslt=$+aliases[lt] aliaslx=$+aliases[lx] "
print "zoxide=$+functions[__navtest_zoxide_loaded]"
'

# run_probe LABEL ROOT -> stdout line; scratch rebuilt per call. A FAKE
# zoxide-init.zsh is planted in the cache: the measured host has no zoxide
# binary, and what is under test is whether zshrc SOURCES that cache at all.
run_probe() {
  label="$1" root="$2"
  scratch="$work/$label"
  rm -rf "$scratch"
  mkdir -p "$scratch/config/zsh" "$scratch/cache/zsh" "$scratch/state/dotfiles"
  ln -sf "$root/zsh/zshenv" "$scratch/config/zsh/.zshenv"
  ln -sf "$root/zsh/zshrc"  "$scratch/config/zsh/.zshrc"
  : > "$scratch/state/dotfiles/update-check.stamp"   # park the fetch
  printf '__navtest_zoxide_loaded() { : }\n' > "$scratch/cache/zsh/zoxide-init.zsh"
  env -u SSH_CONNECTION \
    HOME="$scratch" XDG_CONFIG_HOME="$scratch/config" \
    XDG_CACHE_HOME="$scratch/cache" XDG_STATE_HOME="$scratch/state" \
    XDG_DATA_HOME="$scratch/data" ZDOTDIR="$scratch/config/zsh" TERM=dumb \
    zsh -i -c "$probe" 2>"$scratch/stderr"
}

# copy_root DEST - a full-repo copy for a mutated run. The .git is dropped: a
# cp -a of .git is dead weight and can carry hooks.
copy_root() {
  cp -a "$repo_root" "$1"
  rm -rf "$1/.git"
}

want() {  # want DESC LINE NEEDLE
  case "$2" in *"$3"*) ok "$1" ;; *) fail "$1: expected [$3] in the probe line (got: $2)" ;; esac
}

line="$(run_probe live "$repo_root")" || fail "probe shell failed: $(cat "$work/live/stderr")"
[ -s "$work/live/stderr" ] && fail "startup wrote to stderr: $(cat "$work/live/stderr")"
ok "a full interactive startup is clean on stderr"

# --- the bug: the cached zoxide init is actually sourced -----------------------
want "the cached zoxide init is sourced (\`z\` exists)" "$line" "zoxide=1"

# --- directory stack ----------------------------------------------------------
want "AUTO_PUSHD is on"          "$line" "autopushd=on"
want "PUSHD_IGNORE_DUPS is on"   "$line" "pushdignoredups=on"
want "PUSHD_SILENT is on"        "$line" "pushdsilent=on"
want "CDABLE_VARS is on"         "$line" "cdablevars=on"
want "the \`d\` alias survived startup"   "$line" "aliasd=1"
want "the numeric stack aliases survived" "$line" "alias1=1"

# --- completion ---------------------------------------------------------------
want "COMPLETE_IN_WORD is on" "$line" "completeinword=on"
want "ALWAYS_TO_END is on"    "$line" "alwaystoend=on"
want "PATH_DIRS is on"        "$line" "pathdirs=on"
want "_approximate is in the completer chain" "$line" "approximate=yes"
# Four matchers: case-insensitive both ways, partial-word, substring. Three or
# fewer means the partial/substring pair was dropped and abbreviated paths stop
# completing - the regression that started this work.
want "all four matchers are installed" "$line" "matchers=4"
# The one a static grep cannot make: list-colors is an `-e` style reading
# $LS_COLORS, which aliases.zsh exports AFTER the zstyle is registered. A
# non-zero count proves the lazy lookup actually resolves.
case "$line" in
  *"listcolors=0 "*) fail "list-colors resolved EMPTY - the Tab list is monochrome: $line" ;;
  *"listcolors="*)   ok "list-colors resolves against the exported \$LS_COLORS" ;;
esac
case "$line" in
  *"lscolors=0 "*) fail "\$LS_COLORS is empty after startup: $line" ;;
  *)               ok "\$LS_COLORS is populated after startup" ;;
esac

# --- path highlighting --------------------------------------------------------
if [ "$have_fsyh" = 1 ]; then
  want "f-sy-h path style is the prezto underline"     "$line" "pathstyle=underline"
  want "f-sy-h path-to-dir style is underline as well" "$line" "pathdirstyle=underline"
else
  echo "  SKIP: fast-syntax-highlighting submodule is uninitialized - path styles unmeasured"
  want "the probe reports f-sy-h unloaded in this tree" "$line" "pathstyle=unloaded"
  [ -z "${STRICT:-}" ] || fail "f-sy-h submodule missing and STRICT set (path styles unmeasured)"
fi

# --- regression: the probe survives an f-sy-h that never loaded ---------------
# The live probe reaches the unloaded path only when THIS tree's submodule is
# uninitialized, so it MUST be staged here on every run: the plugin is emptied
# in a copy, exactly what an uninitialized submodule looks like.
nofsyh="$work/nofsyh-root"
copy_root "$nofsyh"
rm -rf "$nofsyh/zsh/plugins/fast-syntax-highlighting"
mkdir "$nofsyh/zsh/plugins/fast-syntax-highlighting"
nline="$(run_probe nofsyh "$nofsyh")" \
  || fail "probe shell failed with f-sy-h unloaded: $(cat "$work/nofsyh/stderr")"
[ -s "$work/nofsyh/cache/zsh/zcompdump" ] \
  || fail "no-f-sy-h copy: its zshrc never ran (no compdump) - the probe measured a default shell"
[ -s "$work/nofsyh/stderr" ] && fail "startup without f-sy-h wrote to stderr: $(cat "$work/nofsyh/stderr")"
want "the probe reports f-sy-h unloaded instead of dying on it" "$nline" "pathstyle=unloaded"

# --- can-fail proof: drop the zoxide source block, the probe MUST notice -------
# Without this the suite could pass against a zshrc that never sources the cache,
# which is precisely how the original defect shipped green.
copy="$work/mutant-root"
copy_root "$copy"
python3 - "$copy/zsh/zshrc" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
old = '''if [[ -r $XDG_CACHE_HOME/zsh/zoxide-init.zsh ]]; then
  source "$XDG_CACHE_HOME/zsh/zoxide-init.zsh"
fi
'''
if s.count(old) != 1:
    sys.exit("mutation setup: the zoxide source block anchor moved (found %d)" % s.count(old))
io.open(p, 'w', encoding='utf-8').write(s.replace(old, ''))
PY
mline="$(run_probe mutant "$copy")" || fail "mutant probe shell failed: $(cat "$work/mutant/stderr")"
# Prove the mutant config actually RAN: a dangling ZDOTDIR would yield a pristine
# shell that exits 0 and reports zoxide=0 for the wrong reason.
[ -s "$work/mutant/cache/zsh/zcompdump" ] \
  || fail "mutation: the mutated zshrc never ran (no compdump) - the probe measured a default shell"
case "$mline" in
  *"zoxide=0"*) ok "removing the zoxide source block IS detected (this test can fail)" ;;
  *) fail "mutation: dropping the zoxide source was NOT detected (got: $mline) - this test proves nothing" ;;
esac

echo "PASS: navigation_state_test ($pass assertions)"
