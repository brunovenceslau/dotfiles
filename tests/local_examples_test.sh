#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Tests the .local.example onboarding TEMPLATES: the zsh and
# Brewfile templates exist and are committable; the zsh template parses under zsh -n
# (it seeds a file sourced into an interactive shell) and is linked by install.sh
# next to its .zshrc.local target; no real secret leaks into it (only commented
# op:// placeholders). Proves each can FAIL - a missing template makes link() refuse,
# a removed install.sh wiring line fails the grep. mktemp workspace; never the real
# $HOME. Not part of the shellcheck surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); }
work="$(mktemp -d "${TMPDIR:-/tmp}/local_examples_test.XXXXXX")"; trap 'rm -rf "$work"' EXIT

# 1. the two templates exist.
for f in zsh/.zshrc.local.example packages/Brewfile.local.example; do
  [ -f "$repo_root/$f" ] || fail "$f is missing"
done
ok

# 1b. both templates are COMMITTABLE (the `!*.local*.example` git-ignore re-include beats
#     the `*.local*` ignore) - else they would never reach a clone. `--no-index` is REQUIRED:
#     plain `check-ignore` short-circuits to "not ignored" on a TRACKED path WITHOUT evaluating
#     any pattern, so without it a broken re-include still passes (a vacuous check).
for f in zsh/.zshrc.local.example packages/Brewfile.local.example; do
  if git -C "$repo_root" check-ignore --no-index -q "$f"; then
    fail "$f is git-ignored - the !*.local*.example re-include is broken"
  fi
done
ok

# 2. the zsh template parses under zsh -n (it is sourced into an interactive shell).
if command -v zsh >/dev/null 2>&1; then
  zsh -n "$repo_root/zsh/.zshrc.local.example" || fail "zsh/.zshrc.local.example does not parse"
  ok
else
  if [ -n "${STRICT:-}" ]; then fail "zsh required under STRICT=1"; fi
  echo "SKIP: zsh unavailable - .zshrc.local.example parse check"
fi

# 3. install.sh WIRES the zsh template via link(): exercise the real link primitive on the
#    actual template file (RED: a missing source makes link() refuse). Mirrors link_test.sh:
#    link() reports through caller-provided log/warn, so stub them.
log() { :; }; warn() { :; }
# shellcheck source=/dev/null
. "$repo_root/lib/link.sh"
dest="$work/zdot/.zshrc.local.example"
link "$repo_root/zsh/.zshrc.local.example" "$dest" || fail "link() refused the zsh template"
[ -L "$dest" ] || fail "the zsh template was not symlinked"
[ "$(readlink "$dest")" = "$repo_root/zsh/.zshrc.local.example" ] || fail "wrong link target"
ok

# 4. install.sh do_link actually carries the wiring line (fences its removal).
grep -qF 'zsh/.zshrc.local.example" "$zdotdir/.zshrc.local.example"' "$repo_root/install.sh" \
  || fail "install.sh do_link is missing the .zshrc.local.example link line"
ok

# 5. no real secret in the template - every op:// ref MUST be commented out (a placeholder).
if grep 'op://' "$repo_root/zsh/.zshrc.local.example" | grep -vqE '^[[:space:]]*#'; then
  fail "an op:// ref in zsh/.zshrc.local.example is not commented out (looks like a real secret)"
fi
ok

# 6. install.sh do_link's BEST-EFFORT guard, BOTH branches, through the REAL entry point
#    (`install.sh link`), mirroring link_prune_test. A cp -a repo copy as $DOTFILES + scratch
#    HOME/XDG (git neutralized); run once WITH the template (must link it), then with the
#    template REMOVED (install must STILL succeed - the fatal-on-missing form once broke
#    smoke/upgrade; and the now-orphan link must be pruned). Fully hermetic.
dots="$work/dots"; cp -a "$repo_root" "$dots"; dots="$(cd "$dots" && pwd -P)"
export HOME="$work/h" \
       XDG_CONFIG_HOME="$work/h/.config" XDG_CACHE_HOME="$work/h/.cache" \
       XDG_STATE_HOME="$work/h/.local/state" \
       GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$HOME"
tmpl_link="$XDG_CONFIG_HOME/zsh/.zshrc.local.example"
"$dots/install.sh" link >"$work/r1.log" 2>&1 \
  || fail "install.sh link (template present) exited nonzero: $(cat "$work/r1.log")"
[ -L "$tmpl_link" ] || fail ".zshrc.local.example was not linked when present"
ok
rm -f "$dots/zsh/.zshrc.local.example"
"$dots/install.sh" link >"$work/r2.log" 2>&1 \
  || fail "install.sh link (template ABSENT) must not fail the install: $(cat "$work/r2.log")"
[ -e "$tmpl_link" ] && fail ".zshrc.local.example link survived after its source was removed (not pruned)"
ok

echo "PASS: local_examples_test ($pass assertions)"
