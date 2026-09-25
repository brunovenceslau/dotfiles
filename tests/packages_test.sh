#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for lib/packages.sh + the manifests. The real brew install needs
# network and is proven by CI; here we test the host-independent logic: the
# Homebrew instruct-and-stop path, the brew bundle order, the fd alias, the gh
# extensions step, and that the manifests are well-formed. Hermetic mktemp
# HOME/DOTFILES; the real system is never touched (no package manager is
# invoked). Not part of the shellcheck surface.
# shellcheck disable=SC2329  # stubs (warn/command) are invoked indirectly
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ck() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail "$1: got [$2] want [$3]"; fi; }

work="$(mktemp -d "${TMPDIR:-/tmp}/packages_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
log() { :; }; warn() { :; }
export DOTFILES="$repo_root"      # real manifests
# shellcheck source=lib/packages.sh
. "$repo_root/lib/packages.sh"

# --- Homebrew instruct-and-stop ---------------------------------
# No brew on PATH: must refuse (nonzero) and print the
# official-method guidance, never attempt a bootstrap. `command` is stubbed so
# `brew` reads as absent without disturbing the real PATH (mkdir/etc still work).
msg="$( warn() { echo "$*"; }
        command() { if [ "$1" = -v ] && [ "$2" = brew ]; then return 1; fi; builtin command "$@"; }
        packages_install 2>&1 )" && rc=0 || rc=$?
ck "brew absent -> nonzero exit" "$rc" "1"
printf '%s\n' "$msg" | grep -qi 'brew.sh' || fail "brew-absent did not point at the official method (brew.sh)"
printf '%s\n' "$msg" | grep -qiE 'will not run|not run a remote' || fail "brew-absent did not disavow a remote bootstrap"

# --- brew happy path: bundle Brewfile then Brewfile.local; propagate failure ----
bdot="$work/bdot"; mkdir -p "$bdot/packages"
printf 'brew "git"\n' > "$bdot/packages/Brewfile"
printf 'brew "extra"\n' > "$bdot/packages/Brewfile.local"
bcalls="$( command() { if [ "$1" = -v ] && [ "$2" = brew ]; then echo /brew; return 0; fi; builtin command "$@"; }
  brew() { echo "brew $*"; }; warn() { :; }; log() { :; }
  . "$repo_root/lib/packages.sh"; DOTFILES="$bdot" packages_install )"
printf '%s\n' "$bcalls" | grep -qF "bundle --file $bdot/packages/Brewfile" || fail "brew: tracked Brewfile not bundled"
printf '%s\n' "$bcalls" | grep -qF "bundle --file $bdot/packages/Brewfile.local" || fail "brew: Brewfile.local not bundled"
brc=0; ( command() { if [ "$1" = -v ] && [ "$2" = brew ]; then return 0; fi; builtin command "$@"; }
  brew() { case "$*" in *Brewfile.local*) return 1;; *) return 0;; esac; }; warn() { :; }; log() { :; }
  . "$repo_root/lib/packages.sh"; DOTFILES="$bdot" packages_install ) || brc=$?
ck "brew: a Brewfile.local failure propagates rc=1" "$brc" "1"

# --- the fd alias (no shim file) ----------------------------------------------
# zsh/aliases.zsh aliases fd -> fdfind ONLY when fdfind is on PATH and no real fd
# is. Drive it with a fake fdfind and a fd-free PATH; assert the alias appears and
# that NO ~/.local/bin/fd file was created (the whole point of dropping the shim).
if command -v zsh >/dev/null 2>&1; then
  export HOME="$work/home"; mkdir -p "$work/home/.local/bin"
  fbin="$work/fbin"; mkdir -p "$fbin"; printf '#!/bin/sh\n' > "$fbin/fdfind"; chmod +x "$fbin/fdfind"
  # `|| true`: `alias fd` returns nonzero when fd is NOT an alias, which would
  # abort the script under set -e before we can assert the empty result.
  al="$(PATH="$fbin:/usr/bin:/bin" HOME="$work/home" ZDOTDIR="$work/home" zsh -fc "source '$repo_root/zsh/aliases.zsh'; alias fd" 2>/dev/null || true)"
  ck "fd alias defined when only fdfind is on PATH" "$al" "fd=fdfind"
  ck "no ~/.local/bin/fd file created (alias, not shim)" "$([ -e "$work/home/.local/bin/fd" ] && echo present || echo absent)" "absent"
  # NEGATIVE case (makes the '(( ! $+commands[fd] ))' half of the guard load-bearing):
  # a real fd on PATH must NOT be shadowed by the alias.
  printf '#!/bin/sh\n' > "$fbin/fd"; chmod +x "$fbin/fd"
  al2="$(PATH="$fbin:/usr/bin:/bin" HOME="$work/home" ZDOTDIR="$work/home" zsh -fc "source '$repo_root/zsh/aliases.zsh'; alias fd" 2>/dev/null || true)"
  ck "no fd alias when a real fd is on PATH (don't shadow it)" "$al2" ""
fi

# --- gh extensions: install PINNED github/gh-stack, idempotent, guarded
# gh is a `gh` extension, not a brew/apt package, so it installs in its own step
# after the OS package step. All hermetic: `command -v gh` and `gh` are stubbed;
# no real gh is invoked. A scratch DOTFILES carries a PINNED gh-extensions.txt
# (each line is `owner/repo <commit-sha|vX.Y.Z>`; install MUST pin).
gdot="$work/gdot"; mkdir -p "$gdot/packages"
gsha="a1b4a3d4d0bcde9ec3a78ab99b2d63af121857a9"   # a real 40-hex commit sha shape
printf 'github/gh-stack %s\n' "$gsha" > "$gdot/packages/gh-extensions.txt"

# (1) gh present, extension NOT yet installed -> installs it, PINNED, with the `--` belt.
gcalls="$(
  command() { if [ "$1" = -v ] && [ "$2" = gh ]; then echo /gh; return 0; fi; builtin command "$@"; }
  gh() { case "$1 $2" in ('extension list') : ;; ('extension install') shift 2; echo "install $*" ;; esac; }
  warn() { :; }; log() { :; }
  . "$repo_root/lib/packages.sh"; DOTFILES="$gdot" _packages_gh_extensions )"
printf '%s\n' "$gcalls" | grep -qF -- "--pin $gsha -- github/gh-stack" \
  || fail "gh: gh-stack not installed pinned with the -- belt (got: $gcalls)"

# (2) idempotent: `gh extension list` already shows it AT ITS PIN -> nothing runs.
# gh prints a git extension's commit as its first 8 characters.
gcalls2="$(
  command() { if [ "$1" = -v ] && [ "$2" = gh ]; then echo /gh; return 0; fi; builtin command "$@"; }
  gh() { case "$1 $2" in ('extension list') printf 'gh stack\tgithub/gh-stack\t%s\n' "${gsha%"${gsha#????????}"}" ;; ('extension '*) echo "$*" ;; esac; }
  warn() { :; }; log() { :; }
  . "$repo_root/lib/packages.sh"; DOTFILES="$gdot" _packages_gh_extensions )"
ck "gh: idempotent - no remove/install when already at the pin" "$(printf '%s\n' "$gcalls2" | grep -cE 'install|remove' || true)" "0"

# (2b) a PIN BUMP reaches a host that already has the extension: the installed
# version differs from the manifest pin -> remove by name, then install at the pin.
tdot="$work/tdot"; mkdir -p "$tdot/packages"
printf 'github/gh-stack v0.2.0\n' > "$tdot/packages/gh-extensions.txt"
gcalls2b="$(
  command() { if [ "$1" = -v ] && [ "$2" = gh ]; then echo /gh; return 0; fi; builtin command "$@"; }
  gh() { case "$1 $2" in ('extension list') printf 'gh stack\tgithub/gh-stack\tv0.1.0\n' ;; ('extension '*) echo "$*" ;; esac; }
  warn() { :; }; log() { :; }
  . "$repo_root/lib/packages.sh"; DOTFILES="$tdot" _packages_gh_extensions )"
ck "gh: pin bump -> remove then install at the new pin" "$(printf '%s ' $gcalls2b)" \
  "extension remove -- gh-stack extension install --pin v0.2.0 -- github/gh-stack "
# The same tag already installed -> nothing runs.
gcalls2c="$(
  command() { if [ "$1" = -v ] && [ "$2" = gh ]; then echo /gh; return 0; fi; builtin command "$@"; }
  gh() { case "$1 $2" in ('extension list') printf 'gh stack\tgithub/gh-stack\tv0.2.0\n' ;; ('extension '*) echo "$*" ;; esac; }
  warn() { :; }; log() { :; }
  . "$repo_root/lib/packages.sh"; DOTFILES="$tdot" _packages_gh_extensions )"
ck "gh: tag pin already installed -> no-op" "$(printf '%s\n' "$gcalls2c" | grep -cE 'install|remove' || true)" "0"

# (2e) a re-pin whose new pin is NOT reachable upstream (offline, or a bad pin)
# never removes the working extension.
gcalls2e="$(
  command() { if [ "$1" = -v ] && [ "$2" = gh ]; then echo /gh; return 0; fi; builtin command "$@"; }
  gh() { case "$1 $2" in ('extension list') printf 'gh stack\tgithub/gh-stack\tv0.1.0\n' ;; ('extension '*) echo "$*" ;; (api*) return 1 ;; esac; }
  warn() { echo "WARN $*"; }; log() { :; }
  . "$repo_root/lib/packages.sh"; DOTFILES="$tdot" _packages_gh_extensions )"
ck "gh: unreachable pin -> nothing removed or installed" "$(printf '%s\n' "$gcalls2e" | grep -cE '^extension (remove|install)' || true)" "0"
printf '%s\n' "$gcalls2e" | grep -q 'not confirmed upstream' \
  || fail "gh: unreachable pin did not warn (got: $gcalls2e)"

# (2f) the new pin is reachable but its install FAILS after the remove: the
# previous version is reinstalled, and the warning prints the exact retry.
gcalls2f="$(
  command() { if [ "$1" = -v ] && [ "$2" = gh ]; then echo /gh; return 0; fi; builtin command "$@"; }
  gh() { case "$1 $2 ${3-} ${4-}" in
      ('extension list '*) printf 'gh stack\tgithub/gh-stack\tv0.1.0\n' ;;
      ('extension install --pin v0.2.0') echo "$*"; return 1 ;;
      ('extension '*) echo "$*" ;;
    esac; }
  warn() { echo "WARN $*"; }; log() { :; }
  . "$repo_root/lib/packages.sh"; DOTFILES="$tdot" _packages_gh_extensions )"
printf '%s\n' "$gcalls2f" | grep -qx 'extension install --pin v0.1.0 -- github/gh-stack' \
  || fail "gh: a failed re-pin did not restore the previous version (got: $gcalls2f)"
printf '%s\n' "$gcalls2f" | grep -qF 'retry: gh extension remove gh-stack; gh extension install --pin v0.2.0 -- github/gh-stack' \
  || fail "gh: a failed re-pin did not print the exact recovery command (got: $gcalls2f)"
pass=$((pass + 2))

# (2d) the installed check matches the EXACT repo, not a substring: only
# owner/gh-foobar is installed, so owner/gh-foo must still be installed.
pdot="$work/pdot"; mkdir -p "$pdot/packages"
printf 'owner/gh-foo v1.0.0\n' > "$pdot/packages/gh-extensions.txt"
gcalls2d="$(
  command() { if [ "$1" = -v ] && [ "$2" = gh ]; then echo /gh; return 0; fi; builtin command "$@"; }
  gh() { case "$1 $2" in ('extension list') printf 'gh foobar\towner/gh-foobar\tv1.0.0\n' ;; ('extension '*) echo "$*" ;; esac; }
  warn() { :; }; log() { :; }
  . "$repo_root/lib/packages.sh"; DOTFILES="$pdot" _packages_gh_extensions )"
ck "gh: prefix collision -> owner/gh-foo still installed, nothing removed" "$(printf '%s ' $gcalls2d)" \
  "extension install --pin v1.0.0 -- owner/gh-foo "

# (3) guard: gh absent -> skip, no install attempt, rc 0 (best-effort, never fatal).
grc=0; gout="$(
  command() { if [ "$1" = -v ] && [ "$2" = gh ]; then return 1; fi; builtin command "$@"; }
  gh() { echo "GH-SHOULD-NOT-RUN $*"; }
  warn() { :; }; log() { :; }
  . "$repo_root/lib/packages.sh"; DOTFILES="$gdot" _packages_gh_extensions )" || grc=$?
ck "gh absent -> returns 0 (best-effort)" "$grc" "0"
! printf '%s\n' "$gout" | grep -q 'GH-SHOULD-NOT-RUN' || fail "gh absent: gh was still invoked"

# (4) validation: a .local line can neither inject a flag/path/URL/glob NOR install an
# UNPINNED extension - only `owner/repo <sha|vX.Y.Z>` survives (assert DROP for each).
gloc="$work/gh-extensions.local.txt"
{
  printf -- '--evil %s\n' "$gsha"          # leading-dash flag token
  printf './evil %s\n' "$gsha"             # dot-leading relative path
  printf -- '-x/y %s\n' "$gsha"            # dash-leading owner
  printf '/tmp/x %s\n' "$gsha"             # absolute path
  printf 'lib*/x %s\n' "$gsha"             # glob
  printf 'https://evil.test/x %s\n' "$gsha" # URL (has ':')
  printf 'notanextension %s\n' "$gsha"     # no slash
  printf 'owner/nopin\n'                    # valid repo, NO pin -> dropped
  printf 'owner/badpin deadbeefzz\n'        # valid repo, non-sha/non-tag pin -> dropped
  printf 'owner/good %s\n' "$gsha"          # valid repo + sha -> passes
  printf 'owner/tagged v1.2.3\n'            # valid repo + release tag -> passes
} > "$gloc"
gv="$(_packages_gh_ext_list "$gdot/packages/gh-extensions.txt" "$gloc")"
ck "gh-ext: github/gh-stack + sha passes"  "$(printf '%s\n' "$gv" | grep -c "^github/gh-stack $gsha\$")" "1"
ck "gh-ext: owner/good + sha passes"       "$(printf '%s\n' "$gv" | grep -c "^owner/good $gsha\$")" "1"
ck "gh-ext: owner/tagged + vX.Y.Z passes"  "$(printf '%s\n' "$gv" | grep -c '^owner/tagged v1.2.3$')" "1"
ck "gh-ext: --evil (flag) dropped"         "$(printf '%s\n' "$gv" | grep -c -- '--evil')" "0"
ck "gh-ext: ./evil (dot path) dropped"     "$(printf '%s\n' "$gv" | grep -c '\./evil')" "0"
ck "gh-ext: -x/y (dash owner) dropped"     "$(printf '%s\n' "$gv" | grep -c -- '-x/y')" "0"
ck "gh-ext: /tmp/x (abs path) dropped"     "$(printf '%s\n' "$gv" | grep -c '/tmp/x')" "0"
ck "gh-ext: glob (*) dropped"              "$(printf '%s\n' "$gv" | grep -c '[*]')" "0"
ck "gh-ext: URL dropped"                   "$(printf '%s\n' "$gv" | grep -c 'https')" "0"
ck "gh-ext: no-slash dropped"              "$(printf '%s\n' "$gv" | grep -c 'notanextension')" "0"
ck "gh-ext: valid repo but NO pin dropped" "$(printf '%s\n' "$gv" | grep -c '^owner/nopin')" "0"
ck "gh-ext: valid repo but BAD pin dropped" "$(printf '%s\n' "$gv" | grep -c '^owner/badpin')" "0"

# (5) packages_install WIRES the gh step in AFTER the brew step. The brew step
# emits OSSTEP and the gh step emits WIRED; asserting OSSTEP-before-WIRED makes the
# ORDER load-bearing (a reversed impl - gh before the packages - fails this, not
# just the presence check).
wcalls="$(
  command() { case "$1 $2" in ('-v brew') echo /brew; return 0 ;; ('-v gh') echo /gh; return 0 ;; esac; builtin command "$@"; }
  brew() { echo OSSTEP; }
  gh() { case "$1 $2" in ('extension list') : ;; ('extension install') echo "WIRED" ;; esac; }
  warn() { :; }; log() { :; }
  . "$repo_root/lib/packages.sh"; DOTFILES="$gdot" packages_install 2>/dev/null )"
printf '%s\n' "$wcalls" | grep -qF "WIRED" \
  || fail "packages_install did not run the gh-extensions step"
flat="$(printf '%s ' $wcalls)"
case "$flat" in
  *OSSTEP*WIRED*) : ;;
  *) fail "packages_install: gh step did not run AFTER the OS package step (got: $flat)" ;;
esac

# (6) best-effort/non-fatal: a `gh extension install` FAILURE must NOT flip
# _packages_gh_extensions NOR packages_install rc, and it MUST warn.
berc=0; bwarn="$(
  command() { case "$1 $2" in ('-v gh') echo /gh; return 0 ;; esac; builtin command "$@"; }
  gh() { case "$1 $2" in ('extension list') : ;; ('extension install') return 1 ;; esac; }
  warn() { echo "WARN $*"; }; log() { :; }
  . "$repo_root/lib/packages.sh"; DOTFILES="$gdot" _packages_gh_extensions )" || berc=$?
ck "gh install failure -> _packages_gh_extensions still rc 0" "$berc" "0"
printf '%s\n' "$bwarn" | grep -qi 'non-fatal' || fail "gh install failure did not warn non-fatal (got: $bwarn)"
prc=0; (
  command() { case "$1 $2" in ('-v brew') echo /brew; return 0 ;; ('-v gh') echo /gh; return 0 ;; esac; builtin command "$@"; }
  brew() { :; }
  gh() { case "$1 $2" in ('extension list') : ;; ('extension install') return 1 ;; esac; }
  warn() { :; }; log() { :; }
  . "$repo_root/lib/packages.sh"; DOTFILES="$gdot" packages_install ) || prc=$?
ck "gh install failure -> packages_install still rc 0 (brew ok)" "$prc" "0"

# --- manifests are well-formed ------------------------------------------------
# Brewfile: every non-comment/non-blank line is a brew/cask/tap directive.
bad="$(grep -vE '^[[:space:]]*(#|$)' "$repo_root/packages/Brewfile" | grep -vE '^(brew|cask|tap|mas) ' || true)"
[ -z "$bad" ] || fail "Brewfile has a non-directive line: $bad"
# gh-extensions.txt: every entry is a valid PINNED owner/repo, and gh-stack is present
# pinned to a release tag or commit SHA (- no floating latest reaches a
# host). gh-stack is a binary extension, so its pin is the vX.Y.Z release tag.
bad="$(_packages_gh_ext_list "$repo_root/packages/gh-extensions.txt" | grep -vE '^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]* ([0-9a-f]{40}|v[0-9]+\.[0-9]+\.[0-9]+)$' || true)"
[ -z "$bad" ] || fail "gh-extensions.txt has an invalid/unpinned owner/repo: $bad"
_packages_gh_ext_list "$repo_root/packages/gh-extensions.txt" | grep -qE '^github/gh-stack (v[0-9]+\.[0-9]+\.[0-9]+|[0-9a-f]{40})$' \
  || fail "gh-extensions.txt: github/gh-stack must be present, pinned to a release tag or commit SHA"
# The macOS-GUI terminal cask lives in the Brewfile. ghostty is the installed cask;
# alacritty ships as config only (its cask is commented out), so the invariant tracks
# ghostty.
grep -q '^cask "ghostty"' "$repo_root/packages/Brewfile" || fail "Brewfile lost the ghostty cask"

echo "PASS: packages_test ($pass assertions)"
