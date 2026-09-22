#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for config/tmux/tmux.conf + config/alacritty/alacritty.toml and
# their .local layers, plus the ipê theme family and its default wiring. tmux is
# driven with a private server socket against a scratch $HOME so the real
# config/server are never touched; alacritty is a GUI (no binary on CI), so its
# TOML is validated with a TOML parser and the import wiring is asserted. Steps
# that need tmux/python3 skip loudly when absent. Not part of the shellcheck
# surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ck() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail "$1: got [$2] want [$3]"; fi; }

work="$(mktemp -d "${TMPDIR:-/tmp}/tmux_alacritty_test.XXXXXX")"
trap 'tmux -L t16test kill-server 2>/dev/null || true; rm -rf "$work"' EXIT INT TERM

# --- the .local layers are gitignored, the .example templates are
# NOT - a broken negation would let a host's .local get committed and PUBLISHED.
# This lives nowhere else in the suite, so pin it here.
for f in config/tmux/tmux.local.conf config/alacritty/alacritty.local.toml; do
  git -C "$repo_root" check-ignore -q "$f" || fail "$f is NOT gitignored"
done
for f in config/tmux/tmux.local.conf.example config/alacritty/alacritty.local.toml.example; do
  if git -C "$repo_root" check-ignore -q "$f"; then fail "$f IS gitignored - the .example must stay tracked"; fi
done
pass=$((pass + 2))

# --- alacritty: valid TOML, imports the .local last, example is placeholder-only
if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null; then
  python3 - "$repo_root" <<'PY' || fail "alacritty TOML checks failed (see above)"
import sys, tomllib
r = sys.argv[1]
base = tomllib.load(open(f"{r}/config/alacritty/alacritty.toml", "rb"))
# Alacritty loads the importing file LAST, so a key
# set directly in alacritty.toml would beat the imports and the per-host .local
# could never override it. So alacritty.toml carries import wiring only - defaults
# first, the ipê default theme next, the .local LAST so it still wins.
assert base["general"]["import"] == ["defaults.toml", "themes/ipe-amarelo.toml", "alacritty.local.toml"], f"import wrong: {base['general'].get('import')}"
# The importing file must set NO content tables inline (they would beat the .local).
for t in ("window", "font", "scrolling"):
    assert t not in base, f"alacritty.toml sets [{t}] inline - it would beat the .local; move it to defaults.toml"
# The portable defaults live in defaults.toml (imported FIRST) and
# ship a tracked window.opacity, so a fresh host looks right with no .local.
defaults = tomllib.load(open(f"{r}/config/alacritty/defaults.toml", "rb"))
assert "opacity" in defaults.get("window", {}), "defaults.toml no longer sets window.opacity"
# no identity/font family baked into the portable defaults (that's per-host -> .local)
assert "normal" not in defaults.get("font", {}), "defaults.toml pins a font family (should be in .local)"
# The four ipê variants exist and are COLOUR-ONLY (only [colors.*],
# no font/opacity/behaviour keys), so they layer cleanly under the import chain.
for v in ("amarelo", "roxo", "rosa", "branco"):
    t = tomllib.load(open(f"{r}/config/alacritty/themes/ipe-{v}.toml", "rb"))
    assert set(t) == {"colors"}, f"ipe-{v}.toml has non-colour tables: {sorted(t)}"
ex = tomllib.load(open(f"{r}/config/alacritty/alacritty.local.toml.example", "rb"))
# the example is a template - it must parse, but carry no absolute paths / secrets
import re
raw = open(f"{r}/config/alacritty/alacritty.local.toml.example").read()
assert "/Users/" not in raw and "/home/" not in raw, "example embeds an absolute home path"
print("alacritty: TOML valid, imports defaults+theme+.local (last), no inline tables, example placeholder-only")
PY
  pass=$((pass + 1))
else
  if [ -n "${STRICT:-}" ]; then fail "python3+tomllib unavailable and STRICT=1 - alacritty TOML not validated"; fi
  echo "  SKIP: python3+tomllib unavailable - alacritty TOML not validated"
fi

# --- tmux: parse, load order, and the -q .local behavior ----------------------
if command -v tmux >/dev/null 2>&1; then
  export HOME="$work"
  mkdir -p "$work/.config/tmux"
  conf="$work/.config/tmux/tmux.conf"
  cp "$repo_root/config/tmux/tmux.conf" "$conf"
  local_conf="$work/.config/tmux/tmux.local.conf"

  # `tmux kill-server` acks before the server process actually exits, so a fast
  # kill -> new-session on the SAME socket races: the new client can attach to the
  # dying server and the fresh config never applies (an empty option read). Spin
  # until the old server is truly gone before starting the next one - deterministic,
  # no sleep. Capped so a wedged server can't hang the suite.
  wait_dead() {
    local n=0
    while tmux -L t16test list-sessions >/dev/null 2>&1; do
      n=$((n + 1)); [ "$n" -ge 2000 ] && break
    done
  }
  # helper: start a server from the conf, read a global option, kill it
  opt() {  # $1 = option name (e.g. @probe or prefix); echoes its value
    tmux -L t16test kill-server 2>/dev/null || true; wait_dead
    tmux -L t16test -f "$conf" new-session -d 2>/dev/null
    tmux -L t16test show-options -gv "$1" 2>/dev/null
    tmux -L t16test kill-server 2>/dev/null || true
  }

  # 1. parses cleanly and applies base settings (prefix C-a, secondary prefix C-b)
  rm -f "$local_conf"
  ck "tmux.conf applies its base (prefix = C-a)" "$(opt prefix)" "C-a"
  ck "tmux.conf keeps C-b as the secondary prefix (prefix2)" "$(opt prefix2)" "C-b"

  # 2. a missing tmux.local.conf is SILENT because of -q. A detached server defers
  # config diagnostics off stderr, so `new-session -d` alone can't see them. Drive
  # the config load through tmux's CONTROL MODE (`-C`, stdin from /dev/null): it
  # loads the config and emits any load diagnostics as TEXT on stdout - fully
  # deterministic, with no pty, no timing window, and no terminal-size or
  # tmux-version sensitivity. (An earlier attempt captured an attached client's
  # status-line RENDER via `script`/zpty; that raced on fast servers and its
  # output routing differs across GNU/BSD `script` and tmux builds - it flaked on
  # the CI legs while passing locally.) Prove -q is LOAD-BEARING: the real conf
  # (with -q) is clean; a copy WITHOUT -q reports "No such file or directory".
  cfg_err() {  # $1 = conf, $2 = pattern; echoes the pattern if it shows in the config-load output
    tmux -L t16test kill-server 2>/dev/null || true; wait_dead
    tmux -L t16test -f "$1" -C new-session -d </dev/null 2>&1 | tr -d '\r' | grep -o "$2" | head -1
    tmux -L t16test kill-server 2>/dev/null || true
  }
  rm -f "$local_conf"
  ck "with -q, a missing .local is silent" "$(cfg_err "$conf" 'No such file or directory')" ""
  noq="$work/noq.conf"; sed 's/source-file -q/source-file/' "$conf" > "$noq"
  ck "without -q, a missing .local nags (guard is load-bearing)" \
    "$(cfg_err "$noq" 'No such file or directory')" "No such file or directory"
  # -q silences a MISSING file only - a PRESENT-but-broken .local must still error
  # loudly, or a real config typo would vanish. (Proves -q is narrowly scoped.)
  printf 'zzbork\n' > "$local_conf"
  ck "a broken .local still errors loudly (-q is missing-file-only)" \
    "$(cfg_err "$conf" 'zzbork')" "zzbork"
  rm -f "$local_conf"

  # 3. a present tmux.local.conf is sourced LAST and wins
  printf 'set -g @probe local-loaded\nset -g prefix C-b\n' > "$local_conf"
  ck ".local is loaded (@probe set)" "$(opt @probe)" "local-loaded"
  ck ".local wins (overrode prefix to C-b)" "$(opt prefix)" "C-b"
  rm -f "$local_conf"
else
  if [ -n "${STRICT:-}" ]; then fail "tmux unavailable and STRICT=1 - tmux.conf not exercised"; fi
  echo "  SKIP: tmux unavailable - tmux.conf not exercised"
fi

# --- both: the reload/source paths use the fixed XDG dir, no stray absolute path
grep -q 'source-file -q ~/.config/tmux/tmux.local.conf' "$repo_root/config/tmux/tmux.conf" \
  || fail "tmux.conf lost its -q .local source line"
grep -q 'bind r source-file ~/.config/tmux/tmux.conf' "$repo_root/config/tmux/tmux.conf" \
  || fail "tmux.conf lost/moved its reload binding (bind r)"
# Truecolor passthrough must cover BOTH targeted terminals: Alacritty ($TERM=alacritty)
# and Ghostty ($TERM=xterm-ghostty, which matches neither *256col* nor alacritty).
grep -q 'alacritty:Tc' "$repo_root/config/tmux/tmux.conf" \
  || fail "tmux.conf lost Alacritty truecolor override (alacritty:Tc)"
grep -q 'xterm-ghostty:RGB' "$repo_root/config/tmux/tmux.conf" \
  || fail "tmux.conf lost Ghostty truecolor override (xterm-ghostty:RGB)"
grep -q '^set -g set-clipboard on' "$repo_root/config/tmux/tmux.conf" \
  || fail "tmux.conf lost OSC 52 clipboard passthrough (set-clipboard on)"
grep -q 'import = \["defaults.toml", "themes/ipe-amarelo.toml", "alacritty.local.toml"\]' "$repo_root/config/alacritty/alacritty.toml" \
  || fail "alacritty.toml import wiring drifted (want defaults first, ipê default theme, .local last)"
pass=$((pass + 3))

echo "PASS: tmux_alacritty_test ($pass assertions)"
