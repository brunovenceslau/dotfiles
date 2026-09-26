#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# canga's zsh completion, both halves of the cached-integration contract:
#
#   PART 1 (generation) - install.sh's _cache_shell_inits, sourced in isolation
#     against a FAKE `canga` on PATH: the cache is written from
#     `canga completion zsh`, an empty generator leaves no cache, and a cache
#     whose binary is gone is removed.
#
#   PART 2 (loading) - a real hermetic `zsh -i -c` against the repo's own
#     zshenv/zshrc with a planted cache: `canga` is registered in $_comps. A
#     cache can be generated and never sourced (zoxide-init.zsh shipped exactly
#     that way, see tests/navigation_state_test.sh), so a cp -a copy with the
#     source block REMOVED must be caught by the same probe.
#
# Hermetic: HOME/XDG and PATH point into a mktemp workspace; the update sentinel
# is parked so the sanctioned detached fetch never fires. The real $HOME and the
# real canga (if any) are never touched.
# shellcheck disable=SC2016  # $probe is zsh source for the MEASURED shell.
set -euo pipefail

# A privilege skip: install.sh refuses root for every subcommand, so nothing
# below can run as root (tests/root_refusal_test.sh covers that refusal).
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  echo "SKIP: canga_completion_test (running as root: install.sh refuses root)"
  exit 0
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ok: $1"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/canga_completion.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# --- PART 1: generation -------------------------------------------------------
# gen MODE -> runs _cache_shell_inits in a subshell with a PATH holding only the
# tools it needs plus, unless MODE=absent, a fake canga. The fake prints a
# sentinel for `completion zsh` (MODE=ok) or nothing (MODE=empty), and records
# its argv so the test proves WHICH subcommand generated the cache.
fakebin="$work/fakebin"
cache="$work/gen/cache/zsh/canga-completion.zsh"
gen() {
  rm -rf "$fakebin"; mkdir -p "$fakebin"
  # The installer needs mktemp/mv/rm/mkdir; link them in rather than inheriting
  # the real PATH, which may carry a real canga, starship or zoxide.
  for t in mktemp mv rm mkdir dirname cat; do
    ln -s "$(command -v "$t")" "$fakebin/$t"
  done
  case "$1" in
    ok)    printf '#!/bin/sh\necho "$*" > "%s/argv"\n[ "$*" = "completion zsh" ] && echo "#compdef canga FAKE-SENTINEL"\n' "$work" > "$fakebin/canga" ;;
    empty) printf '#!/bin/sh\nexit 0\n' > "$fakebin/canga" ;;
    absent) ;;
  esac
  [ -e "$fakebin/canga" ] && chmod +x "$fakebin/canga"
  (
    export HOME="$work/gen/home" XDG_CACHE_HOME="$work/gen/cache" \
      XDG_CONFIG_HOME="$work/gen/config" XDG_STATE_HOME="$work/gen/state"
    # shellcheck source=../install.sh
    . "$repo_root/install.sh"
    PATH="$fakebin" _cache_shell_inits
  ) >"$work/gen.out" 2>&1 || fail "_cache_shell_inits failed ($1): $(cat "$work/gen.out")"
}

gen ok
[ -s "$cache" ] || fail "no canga cache written with canga on PATH: $(cat "$work/gen.out")"
grep -q 'FAKE-SENTINEL' "$cache" || fail "the canga cache does not hold the generator's output"
ok "canga on PATH: the completion is cached"
[ "$(cat "$work/argv")" = "completion zsh" ] || fail "canga was called as [$(cat "$work/argv")], want [completion zsh]"
ok "the cache comes from \`canga completion zsh\`"
# Only canga is on PATH, so its cache must be the directory's ONLY entry: a
# leftover mktemp file or an init-style name would show up here.
listing="$(ls -A "$work/gen/cache/zsh")"
[ "$listing" = "canga-completion.zsh" ] || fail "unexpected files beside the cache: $listing"
ok "no stray temp or init-style file"

gen empty
grep -q 'FAKE-SENTINEL' "$cache" || fail "an empty generator clobbered the previous cache"
ok "an empty generator keeps the previous cache and does not fail the install"
rm -f "$cache"; gen empty
[ ! -e "$cache" ] || fail "an empty generator wrote an empty cache"
ok "an empty generator writes no cache"

gen ok; gen absent
[ ! -e "$cache" ] || fail "the canga cache survived its binary leaving PATH"
ok "a stale cache is removed once canga is gone"

# ~/.local/bin is where canga installs, and only zshrc puts it on PATH. An
# installer run WITHOUT it on PATH (bash, a script, a first install) must still
# find canga there, or it deletes a working cache as "stale".
gen ok
mkdir -p "$work/gen/home/.local/bin"
cp "$work/fakebin/canga" "$work/gen/home/.local/bin/canga"
rm -f "$cache"; gen absent
grep -q 'FAKE-SENTINEL' "$cache" 2>/dev/null \
  || fail "canga in ~/.local/bin but off the installer's PATH got no cache: $(cat "$work/gen.out")"
ok "canga in ~/.local/bin is found without being on the installer's PATH"
rm -rf "$work/gen/home/.local/bin"

# --- PART 2: loading ----------------------------------------------------------
command -v zsh >/dev/null 2>&1 || {
  if [ -n "${STRICT:-}" ]; then fail "zsh not found and STRICT set (loading half not measured)"; fi
  echo "SKIP: zsh not found - the loading half is unmeasured"
  echo "PASS: canga_completion_test ($pass assertions)"
  exit 0
}

probe='print "canga=${_comps[canga]:-none}"'

# run_probe LABEL ROOT -> stdout line. A FAKE cache is planted: what is under test
# is whether zshrc SOURCES it after compinit, not cobra's script.
run_probe() {
  label="$1" root="$2"
  scratch="$work/$label"
  rm -rf "$scratch"
  mkdir -p "$scratch/config/zsh" "$scratch/cache/zsh" "$scratch/state/dotfiles"
  ln -sf "$root/zsh/zshenv" "$scratch/config/zsh/.zshenv"
  ln -sf "$root/zsh/zshrc"  "$scratch/config/zsh/.zshrc"
  : > "$scratch/state/dotfiles/update-check.stamp"   # park the fetch
  printf 'compdef _canga canga\n_canga() { : }\n' > "$scratch/cache/zsh/canga-completion.zsh"
  env -u SSH_CONNECTION \
    HOME="$scratch" XDG_CONFIG_HOME="$scratch/config" \
    XDG_CACHE_HOME="$scratch/cache" XDG_STATE_HOME="$scratch/state" \
    XDG_DATA_HOME="$scratch/data" ZDOTDIR="$scratch/config/zsh" TERM=dumb \
    zsh -i -c "$probe" 2>"$scratch/stderr"
}

line="$(run_probe live "$repo_root")" || fail "probe shell failed: $(cat "$work/live/stderr")"
[ -s "$work/live/stderr" ] && fail "startup wrote to stderr: $(cat "$work/live/stderr")"
[ "$line" = "canga=_canga" ] || fail "canga is not registered after startup (got: $line)"
ok "the cached canga completion is sourced and registered"

# Can-fail proof: drop the source block, the probe MUST notice.
copy="$work/mutant-root"
cp -a "$repo_root" "$copy"
rm -rf "$copy/.git"
python3 - "$copy/zsh/zshrc" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
old = '''if [[ -r $XDG_CACHE_HOME/zsh/canga-completion.zsh ]]; then
  source "$XDG_CACHE_HOME/zsh/canga-completion.zsh"
fi
'''
if s.count(old) != 1:
    sys.exit("mutation setup: the canga source block anchor moved (found %d)" % s.count(old))
io.open(p, 'w', encoding='utf-8').write(s.replace(old, ''))
PY
mline="$(run_probe mutant "$copy")" || fail "mutant probe shell failed: $(cat "$work/mutant/stderr")"
[ -s "$work/mutant/cache/zsh/zcompdump" ] \
  || fail "mutation: the mutated zshrc never ran (no compdump) - the probe measured a default shell"
[ "$mline" = "canga=none" ] \
  || fail "mutation: dropping the canga source was NOT detected (got: $mline) - this test proves nothing"
ok "removing the canga source block IS detected (this test can fail)"

echo "PASS: canga_completion_test ($pass assertions)"
