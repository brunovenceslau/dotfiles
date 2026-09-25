#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# `bin/startup-fork-gate` proves `zsh -i -c exit` invokes no
# external binary - and this test proves the GATE itself can fail, which is the
# assertion's licence to exist (an assertion that cannot fail is decoration).
#
# Four cases, all against cp -a copies of the repo (never the live tree):
#   1. PLANTED violation: a `$(uname -a)` appended to the copy's zshrc MUST turn
#      the gate red, naming the binary. This is the planted-violation discipline
#      of tests/check_patterns_test.sh applied to the derived-assertion gate.
#   2. Pristine copy: the gate MUST pass (the pinned-plugin shims + compinit mv
#      fix hold through the real entry point).
#   3. SHIM DISPLACEMENT (the mac topology): a real dir prepended ahead of the
#      shims - as the zshrc's Homebrew block does on macOS - MUST NOT blind
#      the gate: a violation planted behind such a prepend stays red BY NAME.
#   4. Measurement precondition: with `who` absent from PATH the gate MUST fail
#      LOUDLY (never a quiet pass) - it is the canary binary, so without it an
#      empty fork log cannot be told apart from broken instrumentation.
#
# Hermetic: mktemp + trap; the gate's own scratch lives inside each copy. The
# copies carry .git so the zshrc update-check code path stays real; the gate
# pre-seeds a fresh sentinel so no fetch fires.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v zsh >/dev/null 2>&1 || {
  if [ -n "${STRICT:-}" ]; then fail "zsh not found and STRICT=1"; fi
  echo "SKIP: zsh not found - startup_fork_gate_test needs the measured shell"
  exit 0
}
command -v who >/dev/null 2>&1 || {
  if [ -n "${STRICT:-}" ]; then fail "who not found and STRICT=1"; fi
  echo "SKIP: who not found - the gate's canary precondition cannot be exercised"
  exit 0
}

work="$(mktemp -d "${TMPDIR:-/tmp}/forkgate_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

copy="$work/repo"
cp -a "$repo_root" "$copy"
# The gate's plugin guard must see real submodules in the copy, or every case
# below would measure a degraded shell and this whole test would be vacuous.
[ -e "$copy/zsh/plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh" ] \
  || fail "repo copy lacks plugin submodules - cannot exercise the gate honestly"

# --- 1. Planted violation turns the gate red, naming the binary ---------------
# `uname` as the planted binary is LOAD-BEARING, not arbitrary: the zshrc shims
# `uname` as a function during the plugin loader and `unfunction`s it after, so
# this same case doubles as the guard that the shim was actually removed - a
# surviving function would swallow the planted call and turn THIS case red.
printf '\n__forkgate_planted="$(uname -a)"\nunset __forkgate_planted\n' >> "$copy/zsh/zshrc"
set +e
out="$("$copy/bin/startup-fork-gate" "$copy" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "planted uname -a: gate exited $rc, want 1. Output: $out"
printf '%s\n' "$out" | grep -qF "uname -a" \
  || fail "planted uname -a: gate red but did not NAME the binary. Output: $out"

# --- 2. Pristine copy passes --------------------------------------------------
rm -rf "$copy"
cp -a "$repo_root" "$copy"
set +e
out="$("$copy/bin/startup-fork-gate" "$copy" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "pristine copy: gate exited $rc, want 0. Output: $out"
printf '%s\n' "$out" | grep -qF "no external binary invoked" \
  || fail "pristine copy: gate green without the OK line. Output: $out"

# --- 3. Shim displacement (the mac topology) stays covered --------------------
# On the macs the zshrc prepends the Homebrew prefix AHEAD of the shim dir
# (zshrc:38-46) - the proven false-green vector. The gate's fix rides the
# zshrc's own "$HOME/.local/bin" re-front-load (zshrc:49): simulate the brew
# topology by inserting a REAL-dir prepend just BEFORE that line, plant a
# violation, and demand red BY NAME. An EOF prepend would sit after the
# re-front-load and re-blind the gate - that residual class is documented in
# the gate header (the repo config itself prepends nothing after :49).
rm -rf "$copy"
cp -a "$repo_root" "$copy"
awk '
  /^path=\("\$HOME\/\.local\/bin" \$path\)$/ { print "path=(/usr/bin $path)" }
  { print }
' "$copy/zsh/zshrc" > "$copy/zsh/zshrc.tmp" && mv "$copy/zsh/zshrc.tmp" "$copy/zsh/zshrc"
grep -qxF 'path=(/usr/bin $path)' "$copy/zsh/zshrc" \
  || fail "case 3 setup: the real-dir prepend was not inserted (zshrc anchor moved?)"
printf '\n__forkgate_planted="$(uname -a)"\nunset __forkgate_planted\n' >> "$copy/zsh/zshrc"
set +e
out="$("$copy/bin/startup-fork-gate" "$copy" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "shim displacement: gate exited $rc, want 1 (mac-topology false-green is back?). Output: $out"
printf '%s\n' "$out" | grep -qF "uname -a" \
  || fail "shim displacement: gate red but did not NAME the binary. Output: $out"

# --- 4. who absent -> LOUD failure, never a quiet pass ------------------------
# Mirror every PATH binary as a symlink EXCEPT who, then run the gate under the
# mirror-only PATH. bash 3.2: plain loops, no mapfile.
mirror="$work/nowho"
mkdir -p "$mirror"
old_ifs="$IFS"
IFS=':'
for dir in $PATH; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*; do
    [ -x "$f" ] && [ ! -d "$f" ] || continue
    name="${f##*/}"
    [ "$name" = "who" ] && continue
    [ -e "$mirror/$name" ] || ln -s "$f" "$mirror/$name"
  done
done
IFS="$old_ifs"
set +e
out="$(PATH="$mirror" "$copy/bin/startup-fork-gate" "$copy" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "who absent: gate exited $rc, want a LOUD 1. Output: $out"
printf '%s\n' "$out" | grep -qF "'who' is not on PATH" \
  || fail "who absent: gate failed for the wrong reason. Output: $out"

echo "PASS: startup_fork_gate_test (planted violation caught by name; pristine tree green; mac-topology shim displacement covered; canary precondition fails loudly)"
