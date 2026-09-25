#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Behavioural test: the fast-syntax-highlighting fetch neutralization actually
# SUPPRESSES the runtime theme download on the startup path.
# tests/plugins_test.sh proves the pre-seed LINES EXIST in zshrc by grep; nothing
# proved they WORK. At load, f-sy-h fetches a moving-`master` theme via curl (then wget)
# when $FAST_WORK_DIR/secondary_theme.zsh is absent (plugin.zsh:366). zshrc neutralizes
# this in TWO layers: (1) pre-seed the guard file so the fetch branch is never entered;
# (2) shim curl AND wget to no-ops for the plugin loader, so even an UNWRITABLE
# $XDG_CACHE_HOME - which defeats the pre-seed's write and makes f-sy-h RELOCATE to an
# unseeded dir (plugin.zsh:59) - issues no network call. This sources the REAL zshrc in a
# hermetic zsh with LOGGING curl/wget on PATH and asserts no fetch under writable AND
# unwritable cache, for BOTH the curl and the wget download paths; it then removes each
# layer from a scratch COPY and proves the fetch REAPPEARS, so no assertion is vacuous.
#
# Hermetic: env -i + scratch HOME/XDG_*; DOTFILES points at a SCRATCH copy of zsh/ (+ a
# symlinked lib/) so the loader's `zcompile` writes its derived .zwc into the copy, never
# into the real (SHA-pinned) submodule tree. The loggers are planted in BOTH the exported
# PATH and $HOME/.local/bin, because the rc rebuilds PATH before loading the plugins (a
# host Homebrew's wget would otherwise out-rank them and the negative controls would issue
# a REAL download - measured on a GitHub-hosted macOS runner, whose Homebrew ships wget). No real HOME/repo write, no network egress
# (the logging shims exit 1 before any connect; the curl-absent leg carries no curl at all
# so `type curl` genuinely fails and the wget branch is exercised without touching the
# real curl). Not part of the shellcheck surface.
# shellcheck disable=SC2016  # $-tokens are deliberately literal: generated shim bodies
# ($0/$*), the `zsh -c` script body ($1), and the sed/grep pin patterns ($FAST_WORK_DIR).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
zshrc="$repo_root/zsh/zshrc"
plugin="$repo_root/zsh/plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ck() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail "$1: got [$2] want [$3]"; fi; }

# Both a real zsh and the checked-out plugin working tree are required to exercise the
# fetch branch behaviourally. Their absence leaves the neutralization UNEXERCISED.
missing=""
command -v zsh >/dev/null 2>&1 || missing="zsh"
[ -r "$plugin" ] || missing="${missing:+$missing, }the f-sy-h plugin working tree (submodule not checked out)"
if [ -n "$missing" ]; then
  if [ -n "${STRICT:-}" ]; then
    fail "fsyh_fetch: $missing absent - the startup fetch-neutralization is UNEXERCISED under STRICT=1"
  fi
  echo "note: fsyh_fetch - $missing absent; behavioural startup test skipped (set STRICT=1 to fail closed)" >&2
  echo "PASS: fsyh_fetch_test (0 assertions - $missing absent)"; exit 0
fi
ZSH_ABS="$(command -v zsh)"

work="$(mktemp -d "${TMPDIR:-/tmp}/fsyh_fetch_test.XXXXXX")"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home"

# Isolated DOTFILES: a SCRATCH copy of zsh/ (so `zcompile` writes .zwc here, not into the
# pinned submodule) plus a symlinked lib/ (read-only, the only other subtree zshrc sources).
df="$work/dotfiles"; mkdir -p "$df"
ln -s "$repo_root/lib" "$df/lib"
cp -a "$repo_root/zsh" "$df/zsh"

# Two PATH regimes, each of whose curl/wget are LOGGING binaries reached ONLY when no
# shell-function shim (the fix) shadows them:
#   logbin  - curl+wget loggers FIRST, so `type curl` finds the logger (curl download path)
#             and the real /usr/bin/curl is shadowed (no real network). /usr/bin:/bin
#             follow for the few coreutils the loader may touch.
#   wgetbin - a curl-ABSENT PATH (no /usr/bin) carrying only a wget logger + the coreutils
#             the loader needs, so `type curl` genuinely fails and the WGET branch is taken;
#             zsh is invoked by absolute path since it is not on this PATH.
logbin="$work/logbin"; mkdir -p "$logbin"
printf '#!/bin/sh\necho "FETCH: $0 $*" >> "%s/fetch.log"\nexit 1\n' "$work" > "$logbin/curl"
printf '#!/bin/sh\necho "FETCH: $0 $*" >> "%s/fetch.log"\nexit 1\n' "$work" > "$logbin/wget"
chmod +x "$logbin/curl" "$logbin/wget"
wgetbin="$work/wgetbin"; mkdir -p "$wgetbin"
printf '#!/bin/sh\necho "FETCH: $0 $*" >> "%s/fetch.log"\nexit 1\n' "$work" > "$wgetbin/wget"
chmod +x "$wgetbin/wget"
for t in sed cat rm mkdir chmod dirname; do p="$(command -v "$t")" && ln -s "$p" "$wgetbin/$t"; done

# The rc ASSEMBLES its own PATH before loading the plugins - the Homebrew prefix
# first (when that host has one), then "$HOME/.local/bin" ahead of everything -
# so the PATH this test exports is NOT the PATH the loader searches. A host whose
# Homebrew ships wget (every GitHub-hosted macOS image does) would out-rank a
# logger placed only in $logbin/$wgetbin and turn the negative controls into a
# REAL network download reported as "no fetch". So the loggers are ALSO planted in
# "$HOME/.local/bin", which the rc puts first by its own rule; $logbin/$wgetbin
# still fix what `type curl` finds before the rc runs.
homebin="$work/home/.local/bin"

# Same prefix rule as the rc (zsh/zshrc: -x $prefix/bin/brew, first match wins).
# A curl there cannot be shadowed - $HOME/.local/bin is planted with no curl in
# the curl-absent leg, by construction - and would silently route that leg down
# the curl branch, leaving the wget shim unexercised. Fail loudly instead.
for pfx in /opt/homebrew /usr/local; do
  [ -x "$pfx/bin/brew" ] || continue
  for d in bin sbin; do
    [ -x "$pfx/$d/curl" ] && fail "fsyh_fetch: $pfx/$d/curl would defeat the curl-absent leg (the rc prepends $pfx/$d)"
  done
  break
done

# fetch_attempted <zshrc-file> <cache-writable:0|1> [mode:curl|nocurl]  ->  "yes" | "no"
fetch_attempted() {
  local rc_file="$1" writable="$2" mode="${3:-curl}" cache pdir
  cache="$(mktemp -d "$work/cache.XXXXXX")"
  [ "$writable" = "1" ] || chmod 555 "$cache"
  rm -f "$work/fetch.log"
  # Rebuilt per call: the curl-absent leg must not inherit the curl logger a
  # previous leg planted, or `type curl` succeeds and the wget branch never runs.
  rm -rf "$homebin"; mkdir -p "$homebin"
  cp "$logbin/wget" "$homebin/wget"
  if [ "$mode" = "nocurl" ]; then pdir="$wgetbin"; else pdir="$logbin:/usr/bin:/bin"; cp "$logbin/curl" "$homebin/curl"; fi
  env -i HOME="$work/home" ZDOTDIR="$work/home" \
      XDG_CACHE_HOME="$cache" XDG_STATE_HOME="$work/state" XDG_DATA_HOME="$work/data" \
      XDG_CONFIG_HOME="$work/config" DOTFILES="$df" \
      PATH="$pdir" TERM=xterm \
      "$ZSH_ABS" -fc 'source "$1"' _ "$rc_file" 2>/dev/null || true
  chmod 755 "$cache" 2>/dev/null || true   # let the EXIT trap clean it up
  [ -f "$work/fetch.log" ] && echo yes || echo no
}

# A/B - the REAL zshrc issues NO startup fetch (curl path), writable OR unwritable cache.
ck "real zshrc, writable cache: no startup fetch"           "$(fetch_attempted "$zshrc" 1)" "no"
ck "real zshrc, unwritable cache: no startup fetch"         "$(fetch_attempted "$zshrc" 0)" "no"
# F - the wget download path: curl absent, unwritable cache -> the wget shim also neutralizes.
ck "real zshrc, unwritable cache, curl absent: no wget fetch" "$(fetch_attempted "$zshrc" 0 nocurl)" "no"

# Scratch COPIES with one layer removed - and ASSERT the removal actually took (a no-op
# mutation, e.g. after a reword, must not silently pass these as green).
nofix="$work/zshrc.nofix"
sed -e '/^curl() { return 1 }$/d' -e '/^wget() { return 1 }$/d' \
    -e 's/unfunction uname curl wget/unfunction uname/' "$zshrc" > "$nofix"
grep -q 'curl() { return 1 }' "$nofix" && fail "mutation no-op: curl/wget shim still present in the nofix copy"
grep -q 'unfunction uname curl wget' "$nofix" && fail "mutation no-op: the unfunction line was not reverted in the nofix copy"
noseed="$work/zshrc.noseed_nofix"
sed '/: > "\$FAST_WORK_DIR\/secondary_theme.zsh"/d' "$nofix" > "$noseed"
grep -qF ': > "$FAST_WORK_DIR/secondary_theme.zsh"' "$noseed" && fail "mutation no-op: pre-seed still present in the noseed copy"

# C - fix removed + unwritable cache: the relocation curl fetch REAPPEARS (curl shim load-bearing).
ck "fix removed, unwritable cache: startup FETCHES (curl shim is load-bearing)"      "$(fetch_attempted "$nofix" 0)" "yes"
# G - fix removed + unwritable cache + curl absent: the wget fetch REAPPEARS (wget shim load-bearing).
ck "fix removed, unwritable cache, curl absent: startup FETCHES (wget shim is load-bearing)" "$(fetch_attempted "$nofix" 0 nocurl)" "yes"
# D - fix removed but pre-seed kept + writable cache: the pre-seed ALONE still suffices.
ck "fix removed, pre-seed kept, writable cache: no fetch (pre-seed alone suffices)"  "$(fetch_attempted "$nofix" 1)" "no"
# E - pre-seed AND fix removed + writable cache: the fetch REAPPEARS (the pre-seed is load-bearing).
ck "pre-seed removed, writable cache: startup FETCHES (pre-seed is load-bearing)"    "$(fetch_attempted "$noseed" 1)" "yes"

echo "PASS: fsyh_fetch_test ($pass assertions)"
