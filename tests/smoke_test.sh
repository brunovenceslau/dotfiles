#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for the fresh-install smoke - `make smoke`
# installs into a scratch HOME, proves `zsh -i -c exit` is clean, and re-runs the
# installer to prove idempotency. The arg/repo guards run host-
# independently; a short end-to-end run then proves the driver reports PASS,
# exits 0, writes nothing git can see (hermetic .smoke/ tree), and - the point of
# this file - survives a group/world-writable fpath dir (a GitHub runner
# checkout) where the audited first-compinit path would otherwise abort. Not part
# of the shellcheck surface.
#
# Bash 3.2 compatible so the macOS CI legs behave identically: no associative
# arrays, no mapfile, no ${var,,}.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
smoke="$repo_root/bin/smoke"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$smoke" ] || fail "bin/smoke not found or not executable"

# --- Argument / repo guards (no scratch created before these) -----------------
"$smoke" --help >/dev/null 2>&1 || fail "--help must exit 0"
if "$smoke" --bogus       >/dev/null 2>&1; then fail "unknown option must exit nonzero"; fi
if "$smoke" /nonexistent-xyz >/dev/null 2>&1; then fail "a nonexistent ROOT must exit nonzero"; fi
# A real directory that is not the repo (no install.sh) must be refused, before
# any scratch is built. Kept in-repo under .smoke/ (gitignored) so the guard test
# writes nothing git can see.
notrepo="$repo_root/.smoke/notrepo"
rm -rf "$notrepo"; mkdir -p "$notrepo"
if "$smoke" "$notrepo" >/dev/null 2>&1; then rm -rf "$notrepo"; fail "a non-repo ROOT must exit nonzero"; fi
rm -rf "$notrepo"

# --- End-to-end (needs zsh; loud skip otherwise) ------------------------------
if command -v zsh >/dev/null 2>&1; then
  # Hermeticity: the scratch HOME lives under .smoke/ (gitignored) and any plugin
  # .zwc the shell compiles in-repo are *.zwc-gitignored - neither is git-visible.
  # Comparing porcelain status before/after pins "no git-visible change".
  before="$(cd "$repo_root" && git status --porcelain 2>/dev/null || true)"

  out="$("$smoke" 2>&1)" || fail "smoke end-to-end exited nonzero: $out"
  printf '%s\n' "$out" | grep -q 'PASS' || fail "smoke did not report PASS: $out"

  after="$(cd "$repo_root" && git status --porcelain 2>/dev/null || true)"
  [ "$before" = "$after" ] \
    || fail "smoke left changes git can see (scratch tree not hermetic/gitignored)"

  # The scratch tree must be cleaned up, not left behind.
  [ ! -e "$repo_root/.smoke/run" ] || fail ".smoke/run not cleaned up after a run"

  # CI parity - a group/world-writable fpath dir (what a shared CI runner checkout,
  # or the runner's own /usr/local completion dir, can look like) must NOT abort the
  # smoke. The audited compinit would prompt "ignore insecure dirs?" and, with no
  # TTY, fail that read and abort to stderr - tripping the clean-start check. The
  # smoke pre-seeds the 24h stamp so the warm `compinit -C` path (which skips the
  # audit entirely) runs instead. Prove it by
  # making a real fpath dir 0777 and requiring the smoke to still pass. Only when
  # the plugin fpath dir is present (submodules initialized); perms restored on exit.
  fpdir="$repo_root/zsh/plugins/zsh-completions/src"
  if [ -d "$fpdir" ]; then
    orig_mode="$(stat -c '%a' "$fpdir" 2>/dev/null || stat -f '%Lp' "$fpdir" 2>/dev/null || echo 755)"
    trap 'chmod "$orig_mode" "$fpdir" 2>/dev/null || true' EXIT
    chmod 0777 "$fpdir"
    "$smoke" >/dev/null 2>&1 \
      || fail "smoke aborted on a group/world-writable fpath dir (compinit -C stamp pre-seed regressed)"
    chmod "$orig_mode" "$fpdir" 2>/dev/null || true
    trap - EXIT
  fi

  # Fail-closed clean-start gate, against a noisy-zshrc fixture.
  # Nothing else proves zsh_clean() actually FAILS when the started shell dirties
  # stderr. Point ROOT at a fixture whose real install.sh/lib/bin are symlinked but
  # whose zsh/zshrc is noisy: the smoke installs it, the shell writes to stderr, and
  # the smoke MUST fail FOR THAT REASON. lib/ is linked as a whole DIRECTORY so the
  # fixture can never rot when install.sh grows a new lib/ source (the per-file
  # variant broke exactly that way once: a missing lib/uninstall.sh made the
  # install die first and the bare exit-nonzero assertion passed vacuously). The
  # specific message grep below is the second half of the same defense. `cp`
  # (not `ln`) for zsh/zshenv so its :A resolves DOTFILES to the fixture
  # (self-contained); bin/ is linked so the ~/.local/bin/tmux-status assertion passes
  # en route to the check.
  fix="$repo_root/.smoke/fixture-noisy"
  rm -rf "$fix"; mkdir -p "$fix/zsh"
  ln -sf "$repo_root/install.sh" "$fix/install.sh"
  ln -sf "$repo_root/lib"        "$fix/lib"
  ln -sf "$repo_root/bin"        "$fix/bin"
  cp "$repo_root/zsh/zshenv" "$fix/zsh/zshenv"
  printf 'print -u2 "smoke-fixture: noisy startup"\n' > "$fix/zsh/zshrc"
  fout="$("$smoke" "$fix" 2>&1)" && { rm -rf "$fix"; fail "smoke must exit nonzero when the installed zsh dirties stderr"; }
  printf '%s\n' "$fout" | grep -q 'dirtied stderr' \
    || { rm -rf "$fix"; fail "noisy fixture failed for the WRONG reason (fixture rot?): $fout"; }
  rm -rf "$fix"

  # Fail-closed NO-TRACE gate - proves the uninstall audit would actually fire.
  # Same fixture idiom, but the real zsh config (linked) with a STUB
  # lib/uninstall.sh whose functions no-op: install succeeds, the shell is clean,
  # idempotency holds, dotfiles-uninstall exits 0 having removed nothing - the
  # audit MUST catch the leftovers and fail with its specific message. Guards the
  # snapshot timing, the find predicates, and the comparison logic against rot.
  # lib/ AND the zsh entrypoints are COPIED whole (not per-file) so the fixture
  # can never rot when install.sh or zshrc grows a new source
  # (zsh/update-check.zsh was one such): the *.zsh glob + zshenv/zshrc catch
  # them. Only lib/uninstall.sh is overwritten with the no-op stub. zshenv is
  # copied (not linked) so its :A resolves DOTFILES to the fixture; plugins are
  # omitted (the zshrc degrades gracefully). bin/ is linked.
  fix2="$repo_root/.smoke/fixture-noop-uninstall"
  rm -rf "$fix2"; mkdir -p "$fix2/zsh"
  cp -R "$repo_root/lib" "$fix2/lib"
  cp "$repo_root"/zsh/*.zsh "$fix2/zsh/"                          # aliases, functions, update-check…
  cp "$repo_root/zsh/zshenv" "$repo_root/zsh/zshrc" "$fix2/zsh/"
  ln -sf "$repo_root/install.sh"        "$fix2/install.sh"
  ln -sf "$repo_root/bin"               "$fix2/bin"
  ln -sf "$repo_root/security"          "$fix2/security"
  printf 'uninstall_links() { return 0; }\nuninstall_purge() { return 0; }\n' \
    > "$fix2/lib/uninstall.sh"
  fout="$("$smoke" "$fix2" 2>&1)" && { rm -rf "$fix2"; fail "smoke must fail when uninstall leaves traces (no-op stub passed!)"; }
  printf '%s\n' "$fout" | grep -q 'left a trace' \
    || { rm -rf "$fix2"; fail "noop-uninstall fixture failed for the WRONG reason: $fout"; }
  rm -rf "$fix2"

  # REGRESSION: an optional tool's own cache must land where --purge sweeps.
  # starship keeps its session logs in $STARSHIP_CACHE, default ~/.cache/starship,
  # and the installer's _cache_shell_inits runs `starship init zsh`, so a Mac with
  # starship on PATH got a ~/.cache/starship that --purge never removed. No
  # starship on the Linux PATH meant no Linux run could see it. This stub does
  # what the real binary does - create its cache dir and write a log on every
  # call - and records the dir it used OUTSIDE the scratch HOME, which proves it
  # ran at all (a stub that never ran would make the PASS below vacuous).
  sb="$repo_root/.smoke/stub-starship"
  rm -rf "$sb"; mkdir -p "$sb/bin"
  cat > "$sb/bin/starship" <<'STUB'
#!/bin/sh
d="${STARSHIP_CACHE:-$HOME/.cache/starship}"
mkdir -p "$d" && : > "$d/session_stub.log"
printf '%s\n' "$d" >> "$(dirname "$0")/../calls"
[ "${1:-}" = init ] && printf '%s\n' '# stub starship init: no prompt'
exit 0
STUB
  chmod u+x "$sb/bin/starship"
  sout="$(PATH="$sb/bin:$PATH" "$smoke" 2>&1)" \
    || { rm -rf "$sb"; fail "smoke with starship on PATH must pass (its cache must live under \$XDG_CACHE_HOME/zsh): $sout"; }
  [ -s "$sb/calls" ] || { rm -rf "$sb"; fail "the starship stub never ran - the regression case is vacuous"; }
  if grep -v -E '/\.cache/zsh/starship$' "$sb/calls" >/dev/null; then
    bad_dirs="$(sort -u "$sb/calls")"; rm -rf "$sb"
    fail "starship ran with a cache outside \$XDG_CACHE_HOME/zsh/starship: $bad_dirs"
  fi
  rm -rf "$sb"

  # --keep must retain the scratch tree (a debug branch that swaps the EXIT trap);
  # the default run cleans it (asserted above). An untested whole branch otherwise.
  "$smoke" --keep >/dev/null 2>&1 || fail "--keep must exit 0"
  [ -e "$repo_root/.smoke/run" ] || fail "--keep must retain the scratch tree"
  rm -rf "$repo_root/.smoke/run"
else
  # exempt: the STRICT escalation for smoke's zsh dependency is the dedicated,
  # self-contained block below (it runs bin/smoke under a no-zsh PATH + STRICT=1
  # and asserts fail-closed) - stronger than an inline `fail` here, which would exit
  # before that block runs. In CI (STRICT=1) zsh is always provisioned, so this
  # end-to-end skip never fires there.
  echo "SKIP: zsh unavailable - smoke end-to-end not run"
fi

# --- STRICT fail-closed: zsh absent must fail closed under STRICT --------------
# The STRICT branch is what stops CI greening a gate it never ran; it fires before
# any scratch is built, so only bash + dirname need to be on PATH to reach it.
# A minimal PATH with neither zsh nor the coreutils the scratch phase needs proves
# the early exit: STRICT=1 -> nonzero, no STRICT -> loud skip (exit 0). STRICT is
# set/cleared EXPLICITLY per call and never inherited: under `make local-ci
# STRICT=1`, make exports STRICT=1 into `make test`'s environment, so the no-STRICT
# case must clear it (env -u) or it would inherit STRICT=1 and wrongly fail closed.
nz="$repo_root/.smoke/nozsh-bin"
rm -rf "$nz"; mkdir -p "$nz"
for b in bash dirname; do bp="$(command -v "$b" 2>/dev/null)" && ln -sf "$bp" "$nz/$b"; done
if env -u STRICT PATH="$nz" STRICT=1 "$smoke" >/dev/null 2>&1; then
  rm -rf "$nz"; fail "STRICT=1 with zsh absent must fail closed (exit nonzero)"
fi
env -u STRICT PATH="$nz" "$smoke" >/dev/null 2>&1 || { rm -rf "$nz"; fail "zsh absent without STRICT must skip (exit 0)"; }
rm -rf "$nz"

# --- Wiring: Makefile target + IS a local-ci prerequisite (unlike bench) ------
# Two separate checks, not `A && B || C`: shellcheck reads that form as SC2015,
# and a version that flags it where the local one does not is precisely how a
# CI/local parity trap gets in.
mk="$repo_root/Makefile"
grep -Eq '^smoke:' "$mk" || fail "Makefile has no 'smoke' target"
grep -q 'bin/smoke' "$mk" || fail "Makefile 'smoke' target must call bin/smoke"
# smoke is a blocking gate, so it MUST be a local-ci prerequisite (the inverse of
# the bench test's assertion). grep -w is supported by GNU and macOS BSD grep.
if ! grep -E '^local-ci:' "$mk" | grep -qw smoke; then
  fail "smoke must be a local-ci prerequisite (it is a runnable gate)"
fi

echo "PASS: smoke_test"
