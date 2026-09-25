#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for the plugin layer - zsh plugins vendored
# as SHA-pinned git submodules under zsh/plugins, loaded by a static loader with
# no plugin manager. These assertions read .gitmodules, the superproject index
# and zsh/zshrc, so they hold even when the submodule working trees are NOT
# checked out (the lint/test CI leg does not `submodule update`). Not on the
# repo's shellcheck surface.
#
# Bash 3.2 compatible so the macOS CI legs behave identically: no associative
# arrays, no mapfile, no ${var,,}.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
gitmodules="$repo_root/.gitmodules"
zshrc="$repo_root/zsh/zshrc"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$gitmodules" ] || fail ".gitmodules not found - no submodules added?"

# --- Exactly three ZSH PLUGIN submodules -------------------------------------
# Scoped to zsh/plugins/ rather than counting every submodule in the repo, so a
# future vendored tree elsewhere cannot make this read "a zsh plugin appeared"
# when none did. The scoped count still catches the thing it exists to catch: an
# unreviewed FOURTH plugin on the startup path.
n="$(git config -f "$gitmodules" --get-regexp '\.path$' | awk '{print $2}' \
      | grep -c '^zsh/plugins/' || true)"
[ "$n" -eq 3 ] || fail "expected 3 zsh plugin submodules, found $n"

# zsh/plugins/ is the ONLY sanctioned submodule location; anything else is an
# unreviewed third-party tree in the repo.
bad="$(git config -f "$gitmodules" --get-regexp '\.path$' | awk '{print $2}' \
        | grep -v '^zsh/plugins/' || true)"
[ -z "$bad" ] || fail "submodule(s) outside zsh/plugins/: $bad"

# --- Each plugin: exact-SHA pin, https url, ignore=untracked ------------------
# Expected SHAs are the commits the approved release tags point at (v0.7.1,
# 0.36.0, v1.56, v1.28.1). v1.56 and v1.28.1 are annotated tags, so the pinned
# commit differs from the tag object's own SHA - a submodule gitlink is always a
# commit. A bump is a reviewable change to these constants.
check_pin() { # name expected_commit_sha
  name="$1"; want="$2"; path="zsh/plugins/$name"
  got="$(git -C "$repo_root" ls-files -s -- "$path" | awk '{print $2}')"
  [ -n "$got" ] || fail "$path: no gitlink in index (submodule not added?)"
  [ "$got" = "$want" ] || fail "$path: pinned to $got, expected $want"
  url="$(git config -f "$gitmodules" --get "submodule.$path.url")"
  case "$url" in
    https://*) : ;;
    *) fail "$path: url must be https (no credentials for CI): $url" ;;
  esac
  ign="$(git config -f "$gitmodules" --get "submodule.$path.ignore" || true)"
  [ "$ign" = "untracked" ] \
    || fail "$path: ignore='$ign', expected 'untracked' (generated .zwc must not dirty status)"
}
check_pin zsh-autosuggestions      e52ee8ca55bcc56a17c828767a3f98f22a68d4eb
check_pin zsh-completions          28c5bdcaf81bb89e56d0df8267d822c3b8aed9e0
check_pin fast-syntax-highlighting 5ecd353c81214f82bdeca5483fab6ccc5a2d5494

# --- Static loader shape in zsh/zshrc -----------------------------------------
[ -f "$zshrc" ] || fail "zsh/zshrc not found"
need() { grep -q -- "$1" "$zshrc" || fail "loader: missing $2"; }
need 'plugins/zsh-completions/src'  "zsh-completions on fpath"
need 'autoload -Uz compinit'        "compinit (ordering anchor)"
need 'plugins/zsh-autosuggestions/zsh-autosuggestions.zsh'                    "autosuggestions source"
need 'plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh'   "f-sy-h source"

# f-sy-h fetches a theme from a moving `master` ref at
# load time unless its guard file is pre-seeded. The loader must pin
# FAST_WORK_DIR and pre-create secondary_theme.zsh before sourcing f-sy-h.
need 'export FAST_WORK_DIR'         "FAST_WORK_DIR pin (neutralize f-sy-h master fetch)"
need 'secondary_theme.zsh'          "secondary_theme.zsh pre-seed (suppress runtime download)"

# The final .zshrc.local hook must be an if/fi block, not a bare `[[ .. ]] &&`
# (a bare && leaks exit 1 to `zsh -i -c exit` on a host without a .zshrc.local).
grep -qF 'if [[ -r $ZDOTDIR/.zshrc.local ]]; then' "$zshrc" \
  || fail "exit-code: .zshrc.local hook must be an if/fi block"
if grep -qF '[[ -r $ZDOTDIR/.zshrc.local ]] &&' "$zshrc"; then
  fail "exit-code: bare '[[ .zshrc.local ]] &&' leaks non-zero exit on hosts without a .local"
fi

# Line-order invariants. grep -m1 (not `| head -1`) so pipefail cannot turn a
# future multi-match into a cryptic SIGPIPE abort.
line_of() { grep -m1 -n -- "$1" "$zshrc" | cut -d: -f1; }
fpath_ln="$(line_of 'plugins/zsh-completions/src')"
compinit_ln="$(line_of 'autoload -Uz compinit')"
as_ln="$(line_of 'zsh-autosuggestions/zsh-autosuggestions.zsh')"
fsh_ln="$(line_of 'fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh')"
neutralize_ln="$(line_of 'export FAST_WORK_DIR')"

# fpath entries must precede compinit so the cached dump indexes the completions.
[ "$fpath_ln" -lt "$compinit_ln" ] \
  || fail "plugin fpath (line $fpath_ln) must precede compinit (line $compinit_ln)"
# f-sy-h must be the last plugin sourced so it wraps every ZLE widget above it.
[ "$fsh_ln" -gt "$as_ln" ] \
  || fail "f-sy-h (line $fsh_ln) must be sourced after autosuggestions (line $as_ln)"
# The fetch neutralization must run before f-sy-h is sourced.
[ "$neutralize_ln" -lt "$fsh_ln" ] \
  || fail "FAST_WORK_DIR pin (line $neutralize_ln) must precede f-sy-h source (line $fsh_ln)"

# --- Gate scoping: pinned plugins excluded from the static-pattern checks ------
# The check-patterns logic lives in bin/check-patterns (a thin make target invokes
# it). EVERY recursive scan there MUST exclude the zsh plugin submodules (we police
# our own code, not upstream's) AND self-exclude the checker, which necessarily
# spells out the forbidden literals in its own patterns/docs.
#
# Tied to the NUMBER of recursive scans, never to a fixed count: a hardcoded 2 fails
# the moment a correctly-scoped arm is added, which teaches the next author to bump
# the number instead of reading the invariant. What must hold is one exclusion pair
# PER recursive scan. Both flags sit on the recursive grep's own line, so counting
# lines is the same test. The floor keeps this from passing vacuously if the
# recursive scans ever disappear.
#
# The scan is matched by SHAPE, not by one literal spelling: `-rn`, `-nr`, `-Irn`,
# `-RIn` and `--recursive` all count. Keying on `grep -rI` alone would let an unscoped
# recursive arm ship with the counts still balanced, and `-R` is the MORE dangerous
# spelling (it follows symlinks back into the pinned plugin trees), so it must not be
# the one that slips. Comments are stripped first, TRAILING ones included, so prose
# about these flags can never inflate one side and fail the suite spuriously.
cp="$repo_root/bin/check-patterns"
code="$(sed -E 's/(^|[[:space:];&|()])#.*$/\1/' "$cp")"
n_rec="$(printf '%s\n' "$code" | grep -cE 'grep[[:space:]]+-([A-Za-z]*[rR]|-recursive)' || true)"
[ "$n_rec" -ge 2 ] \
  || fail "bin/check-patterns must keep at least its two original recursive scans (found $n_rec)"
n_ex="$(printf '%s\n' "$code" | grep -c -- '--exclude-dir=plugins' || true)"
[ "$n_ex" -eq "$n_rec" ] \
  || fail "bin/check-patterns must carry --exclude-dir=plugins on every recursive grep line ($n_rec scans, $n_ex exclusions)"
n_self="$(printf '%s\n' "$code" | grep -c -- '--exclude=check-patterns' || true)"
[ "$n_self" -eq "$n_rec" ] \
  || fail "bin/check-patterns must self-exclude via --exclude=check-patterns on every recursive grep line ($n_rec scans, $n_self self-excludes)"

echo "PASS: plugins_test"
