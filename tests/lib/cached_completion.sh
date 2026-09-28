# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# tests/lib/cached_completion.sh - shared PART 1 (generation, against a FAKE
# binary) and PART 2 (loading, a real hermetic `zsh -i -c`) assertions for the
# cached-completion contract that canga and sbx both ride: install.sh's
# _cache_shell_inits writes `<tool>-completion.zsh` from `<tool> completion
# zsh`, and zsh/zshrc sources it guarded on the binary being present
# ($+commands) AND the cache file being readable ([[ -r ]]).
# Sourced, never run: `make test` globs tests/*.sh only, not this dir.
#
# The caller (tests/canga_completion_test.sh, tests/sbx_completion_test.sh) is
# a thin wrapper: `set -euo pipefail`, `. tests/lib/cached_completion.sh`,
# `run_cached_completion_suite <tool>`. Everything else - root-skip, the
# mktemp workspace, every assertion - lives here so a fix lands once for both
# tools instead of drifting between two near-identical copies.
#
# Hermetic: HOME/XDG and PATH point into a mktemp workspace; the update
# sentinel is parked so the sanctioned detached fetch never fires. The real
# $HOME and the real tool binary (if any - canga is genuinely installed on
# this project's own dev/CI hosts) are never touched or relied upon: every
# probe below builds its own PATH rather than trusting the ambient one.
#
# Not bash-3.2 constrained: that rule (see CLAUDE.md) scopes to install.sh and
# lib/, which run under macOS's /bin/bash; this only ever runs under `make
# test`'s bash.
# shellcheck shell=bash disable=SC2016  # $probe is zsh source for the MEASURED shell.

_cc_fail() { echo "FAIL: $*" >&2; exit 1; }
_cc_pass=0
_cc_ok() { _cc_pass=$((_cc_pass + 1)); echo "  ok: $1"; }
# Global, not local: the EXIT trap fires after run_cached_completion_suite has
# already returned (see where it's set), so it cannot read that function's
# own `local work` - a `local` goes out of scope with the frame that declared
# it, whatever quoting the trap string uses.
_cc_work=""

# _cc_gen MODE - runs _cache_shell_inits in a subshell with a PATH holding only
# the tools it needs plus, per MODE, a fake $tool. Reads/writes the caller's
# $tool, $work, $fakebin (dynamic scoping: this is called from inside
# run_cached_completion_suite's stack frame, so its `local`s are visible here).
#   ok        prints `#compdef $tool FAKE-SENTINEL` for `completion zsh`
#   empty     exits 0 with no output
#   badformat prints a non-completion line, exit 0 (the `#compdef <tool>`
#             first-line check must reject this like an empty generator)
#   nonzero   prints a partial `#compdef $tool` line, THEN exits 1 (a
#             generator that fails after writing SOME stdout must not leave a
#             partial script cached)
#   absent    no binary at all
# and records the fake's argv so the test proves WHICH subcommand generated
# the cache.
_cc_gen() {
  rm -rf "$fakebin"; mkdir -p "$fakebin"
  # The installer needs mktemp/mv/rm/mkdir/head; link them in rather than
  # inheriting the real PATH, which may carry a real canga, sbx, starship or
  # zoxide.
  local t
  for t in mktemp mv rm mkdir dirname cat head; do
    ln -s "$(command -v "$t")" "$fakebin/$t"
  done
  case "$1" in
    # Real line order (measured on sbx v0.45.1): `#compdef <tool>` is the
    # FIRST line, on its own - the install.sh check now rejects anything
    # else there, so the sentinel must live on a later line.
    ok)        printf '#!/bin/sh\necho "$*" > "%s/argv"\nif [ "$*" = "completion zsh" ]; then printf "#compdef %s\\nFAKE-SENTINEL\\n"; fi\n' "$work" "$tool" > "$fakebin/$tool" ;;
    empty)     printf '#!/bin/sh\nexit 0\n' > "$fakebin/$tool" ;;
    badformat) printf '#!/bin/sh\necho "$*" > "%s/argv"\necho "not a completion script"\n' "$work" > "$fakebin/$tool" ;;
    nonzero)   printf '#!/bin/sh\necho "$*" > "%s/argv"\nprintf "#compdef %s\\n"\nexit 1\n' "$work" "$tool" > "$fakebin/$tool" ;;
    absent)    ;;
  esac
  [ -e "$fakebin/$tool" ] && chmod u+x "$fakebin/$tool"
  (
    export HOME="$work/gen/home" XDG_CACHE_HOME="$work/gen/cache" \
      XDG_CONFIG_HOME="$work/gen/config" XDG_STATE_HOME="$work/gen/state"
    # shellcheck source=../../install.sh
    . "$repo_root/install.sh"
    PATH="$fakebin" _cache_shell_inits
  ) >"$work/gen.out" 2>&1 || _cc_fail "_cache_shell_inits failed ($1): $(cat "$work/gen.out")"
}

# _cc_run_probe LABEL ROOT PLANT [BINMODE] - a real hermetic `zsh -i -c`
# against ROOT's own zshenv/zshrc. PLANT is "plant" (write a fake
# $tool-completion.zsh cache first) or "noplant". BINMODE is "bin" (default: a
# no-op executable named $tool goes on PATH, so $+commands[$tool] is true) or
# "nobin" ($tool is kept off the constructed PATH, whatever the ambient PATH
# holds - see the filter below). Sets $_cc_probe_out to the probe's stdout;
# stderr lands in $work/$LABEL/stderr for the caller to assert on.
_cc_run_probe() {
  local label="$1" root="$2" plant="$3" binmode="${4:-bin}"
  local scratch="$work/$label" d

  rm -rf "$scratch"
  mkdir -p "$scratch/config/zsh" "$scratch/cache/zsh" "$scratch/state/dotfiles" "$scratch/toolbin"
  ln -sf "$root/zsh/zshenv" "$scratch/config/zsh/.zshenv"
  ln -sf "$root/zsh/zshrc"  "$scratch/config/zsh/.zshrc"
  : > "$scratch/state/dotfiles/update-check.stamp"   # park the fetch

  if [ "$plant" = plant ]; then
    printf 'compdef _%s %s\n_%s() { : }\n' "$tool" "$tool" "$tool" > "$scratch/cache/zsh/$tool-completion.zsh"
  fi

  local probe_path
  if [ "$binmode" = bin ]; then
    # A no-op executable named $tool: what is under test is zshrc's
    # ($+commands[$tool] && [[ -r cache ]]) guard, not the real binary's own
    # behaviour, so a stub is enough and keeps this deterministic whether or
    # not the real tool happens to be installed on the host running the tests.
    printf '#!/bin/sh\nexit 0\n' > "$scratch/toolbin/$tool"
    chmod u+x "$scratch/toolbin/$tool"
    probe_path="$scratch/toolbin:/usr/bin:/bin"
  else
    # "nobin" must hold even when a REAL $tool sits on this host's ambient
    # PATH (canga does, on this project's own dev/CI hosts) - filter every
    # PATH entry that would resolve $tool out, rather than trusting a fixed
    # allowlist that could go stale.
    probe_path=""
    local IFS=:
    for d in $PATH; do
      [ -x "$d/$tool" ] && continue
      probe_path="$probe_path:$d"
    done
    probe_path="${probe_path#:}"
  fi
  # zsh itself must still resolve, but appending the directory it lives in
  # (rather than just the binary) can silently undo the filter above: a
  # Homebrew zsh (`brew install zsh`) shares /opt/homebrew/bin with a
  # Homebrew-installed $tool, so appending that whole directory re-exposes
  # exactly what "nobin" just excluded. Symlink only the zsh binary itself
  # into a scratch dir instead of trusting what else lives beside it.
  mkdir -p "$scratch/zshbin"
  ln -sf "$(command -v zsh)" "$scratch/zshbin/zsh"
  probe_path="$probe_path:$scratch/zshbin:/usr/bin:/bin:/usr/sbin:/sbin"

  env -u SSH_CONNECTION \
    HOME="$scratch" XDG_CONFIG_HOME="$scratch/config" \
    XDG_CACHE_HOME="$scratch/cache" XDG_STATE_HOME="$scratch/state" \
    XDG_DATA_HOME="$scratch/data" ZDOTDIR="$scratch/config/zsh" TERM=dumb \
    PATH="$probe_path" \
    zsh -i -c "$probe" >"$scratch/stdout" 2>"$scratch/stderr" \
    || _cc_fail "probe shell failed ($label): $(cat "$scratch/stderr")"
  _cc_probe_out="$(cat "$scratch/stdout")"
}

# _cc_hermetic_prefix_copy DEST PREFIX_DIR - a tarred copy of $repo_root (same
# recipe as the source-block mutants below) whose zsh/zshrc brew-prefix loop
# (zsh/zshrc:46-53, `for prefix in /opt/homebrew /usr/local; do`) is rewritten,
# anchor-checked, to search ONLY PREFIX_DIR. That loop checks two HARDCODED
# real filesystem locations for an executable bin/brew, independent of
# whatever PATH a probe constructs - see the F1 comment where this is called.
_cc_hermetic_prefix_copy() {
  local dest="$1" prefix_dir="$2"
  mkdir -p "$dest"
  tar -C "$repo_root" -cf - . | tar -C "$dest" -xf -
  rm -rf "$dest/.git"
  python3 - "$dest/zsh/zshrc" "$prefix_dir" <<'PY'
import io, sys
p, prefix_dir = sys.argv[1], sys.argv[2]
s = io.open(p, encoding='utf-8').read()
old = 'for prefix in /opt/homebrew /usr/local; do'
new = 'for prefix in %r; do' % prefix_dir
if s.count(old) != 1:
    sys.exit("mutation setup: the brew-prefix loop anchor moved (found %d)" % s.count(old))
io.open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
}

# run_cached_completion_suite TOOL - the full contract test for TOOL (canga or
# sbx), printing the same PASS/FAIL/SKIP shape as any other tests/*.sh script.
run_cached_completion_suite() {
  local tool="$1"
  local repo_root work fakebin cache listing line probe copy copy2
  local empty_prefix decoy_prefix stale_copy canary_copy saved_probe
  local homebrew_zsh_dir saved_path

  # A privilege skip: install.sh refuses root for every subcommand, so nothing
  # below can run as root (tests/root_refusal_test.sh covers that refusal).
  if [ "$(/usr/bin/id -u)" -eq 0 ]; then
    echo "SKIP: ${tool}_completion_test (running as root: install.sh refuses root)"
    return 0
  fi

  # BASH_SOURCE[0] here is THIS file (tests/lib/cached_completion.sh), two
  # levels below the repo root - not the wrapper script that sourced it.
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  work="$(mktemp -d "${TMPDIR:-/tmp}/${tool}_completion.XXXXXX")"
  # $_cc_work is a global (see its declaration) so the EXIT trap - which only
  # fires after this function returns - can still read it, and single-quoted
  # so a `'` in $work (unlikely, but mktemp's charset is not our contract)
  # cannot break the trap's own quoting.
  _cc_work="$work"
  trap 'rm -rf -- "$_cc_work"' EXIT

  fakebin="$work/fakebin"
  cache="$work/gen/cache/zsh/$tool-completion.zsh"

  # --- PART 1: generation -------------------------------------------------------
  _cc_gen ok
  [ -s "$cache" ] || _cc_fail "no $tool cache written with $tool on PATH: $(cat "$work/gen.out")"
  grep -q 'FAKE-SENTINEL' "$cache" || _cc_fail "the $tool cache does not hold the generator's output"
  _cc_ok "$tool on PATH: the completion is cached"
  [ "$(cat "$work/argv")" = "completion zsh" ] || _cc_fail "$tool was called as [$(cat "$work/argv")], want [completion zsh]"
  _cc_ok "the cache comes from \`$tool completion zsh\`"
  # Only $tool is on PATH, so its cache must be the directory's ONLY entry: a
  # leftover mktemp file or an init-style name would show up here.
  listing="$(ls -A "$work/gen/cache/zsh")"
  [ "$listing" = "$tool-completion.zsh" ] || _cc_fail "unexpected files beside the cache: $listing"
  _cc_ok "no stray temp or init-style file"

  _cc_gen empty
  grep -q 'FAKE-SENTINEL' "$cache" || _cc_fail "an empty generator clobbered the previous cache"
  _cc_ok "an empty generator keeps the previous cache and does not fail the install"
  rm -f "$cache"; _cc_gen empty
  [ ! -e "$cache" ] || _cc_fail "an empty generator wrote an empty cache"
  _cc_ok "an empty generator writes no cache"

  # `[ -s ]` alone accepts any non-empty noise. A generator whose output is
  # not a `#compdef <tool>` completion script must be treated like an empty
  # one - never cached.
  _cc_gen ok; rm -f "$cache"
  _cc_gen badformat
  [ ! -e "$cache" ] || _cc_fail "a malformed (non-#compdef) generator output was cached"
  _cc_ok "a generator whose output is not a completion script writes no cache"

  # A generator that writes SOME stdout and then exits non-zero must not
  # leave a partial script cached.
  _cc_gen ok; rm -f "$cache"
  _cc_gen nonzero
  [ ! -e "$cache" ] || _cc_fail "a generator that exited non-zero after partial stdout was cached"
  _cc_ok "a generator that fails after partial stdout writes no cache"

  _cc_gen ok; _cc_gen absent
  [ ! -e "$cache" ] || _cc_fail "the $tool cache survived its binary leaving PATH"
  _cc_ok "a stale cache is removed once $tool is gone"

  # ~/.local/bin is where canga installs, and only zshrc puts it on PATH.
  # install.sh resolves every tool the same way, so this case proves
  # install.sh's shared ~/.local/bin resolution, not anything specific to
  # $tool's own installer conventions. An installer run WITHOUT it on PATH
  # (bash, a script, a first install) must still find $tool there, or it
  # deletes a working cache as "stale".
  _cc_gen ok
  mkdir -p "$work/gen/home/.local/bin"
  cp "$work/fakebin/$tool" "$work/gen/home/.local/bin/$tool"
  rm -f "$cache"; _cc_gen absent
  grep -q 'FAKE-SENTINEL' "$cache" 2>/dev/null \
    || _cc_fail "$tool in ~/.local/bin but off the installer's PATH got no cache: $(cat "$work/gen.out")"
  _cc_ok "$tool in ~/.local/bin is found without being on the installer's PATH"
  rm -rf "$work/gen/home/.local/bin"

  # --- PART 2: loading -----------------------------------------------------------
  command -v zsh >/dev/null 2>&1 || {
    if [ -n "${STRICT:-}" ]; then _cc_fail "zsh not found and STRICT set (loading half not measured)"; fi
    echo "SKIP: zsh not found - the loading half is unmeasured"
    echo "PASS: ${tool}_completion_test ($_cc_pass assertions)"
    return 0
  }

  probe="print \"$tool=\${_comps[$tool]:-none}\""

  _cc_run_probe live "$repo_root" plant
  line="$_cc_probe_out"
  [ -s "$work/live/stderr" ] && _cc_fail "startup wrote to stderr: $(cat "$work/live/stderr")"
  [ "$line" = "$tool=_$tool" ] || _cc_fail "$tool is not registered after startup (got: $line)"
  _cc_ok "the cached $tool completion is sourced and registered"

  # Nothing proved the `[[ -r ]]` guard is load-bearing on its own - a planted
  # cache always existed, so a zshrc that sourced an unconditional literal
  # path would pass just as well. Run the SAME probe with NO cache planted:
  # the guard must skip it silently, no stderr, no registration.
  _cc_run_probe nocache "$repo_root" noplant
  line="$_cc_probe_out"
  [ -s "$work/nocache/stderr" ] && _cc_fail "no cache planted but startup wrote to stderr: $(cat "$work/nocache/stderr")"
  [ "$line" = "$tool=none" ] || _cc_fail "no cache planted but $tool was registered anyway (got: $line)"
  _cc_ok "no cache means no completion, and no stderr (the [[ -r ]] guard is load-bearing)"

  # A STALE cache survives an uninstall - it is only cleaned up at install,
  # link or upgrade time (install.sh's _cache_shell_inits) - so it must not
  # register a completion for a binary that is no longer on PATH. Plant the
  # cache but keep $tool off PATH: the ($+commands) guard must skip it too.
  #
  # F1 (ship-gate finding): zsh/zshrc:46-53 re-derives $path by checking two
  # HARDCODED real filesystem locations, /opt/homebrew and /usr/local, for an
  # executable bin/brew - independent of whatever PATH this probe passes in.
  # On a real dev machine where Homebrew and $tool live under one of those
  # prefixes, that block silently re-adds $tool to $path no matter how
  # "nobin" tried to exclude it, making $+commands[$tool] true regardless and
  # failing this assertion on that machine even though the guard is correct.
  # Measured on the operator's mac: sbx is at /opt/homebrew/bin (a Homebrew
  # prefix) - canga there is at ~/.local/bin instead, but a Homebrew-installed
  # canga is exactly as plausible on another host. Run against a copy whose
  # loop is redirected to an EMPTY scratch prefix instead of trusting the real
  # host to have no Homebrew there.
  empty_prefix="$work/prefix-empty"; mkdir -p "$empty_prefix"
  # A decoy prefix that DOES hold brew and $tool, exactly like a real
  # Homebrew install - built for the faithfulness canary below, which is the
  # actual proof that the redirect isolates the probe (not this decoy's mere
  # existence): it points the SAME mechanism at this prefix and confirms
  # zsh's own loop really does pick it up.
  decoy_prefix="$work/prefix-decoy-brew"
  mkdir -p "$decoy_prefix/bin"
  printf '#!/bin/sh\nexit 0\n' > "$decoy_prefix/bin/brew"
  printf '#!/bin/sh\nexit 0\n' > "$decoy_prefix/bin/$tool"
  chmod u+x "$decoy_prefix/bin/brew" "$decoy_prefix/bin/$tool"

  stale_copy="$work/stale-root"
  _cc_hermetic_prefix_copy "$stale_copy" "$empty_prefix"
  _cc_run_probe stale "$stale_copy" plant nobin
  line="$_cc_probe_out"
  [ -s "$work/stale/stderr" ] && _cc_fail "stale cache, $tool absent, but startup wrote to stderr: $(cat "$work/stale/stderr")"
  [ "$line" = "$tool=none" ] \
    || _cc_fail "a stale cache with $tool absent from PATH registered a completion anyway (got: $line) - even with the brew-prefix loop redirected away from the decoy Homebrew-style prefix sitting unused in the workspace"
  _cc_ok "a stale cache with $tool absent from PATH is not sourced (the \$+commands guard is load-bearing, hermetic to the host's real Homebrew prefix)"

  # A Homebrew-zsh proof (ship-gate finding): simulate `brew install zsh`
  # sharing its prefix bin dir with a Homebrew-installed $tool - the exact
  # layout that used to defeat _cc_run_probe's own "nobin" filter, since the
  # old code appended THAT WHOLE DIRECTORY (to make `zsh` itself resolvable)
  # after already filtering $tool out of it. Prepending this fixture to the
  # ambient PATH makes `command -v zsh` resolve into it, exercising the fixed
  # symlink-only append above.
  homebrew_zsh_dir="$work/homebrew-zsh-prefix/bin"
  mkdir -p "$homebrew_zsh_dir"
  ln -sf "$(command -v zsh)" "$homebrew_zsh_dir/zsh"
  printf '#!/bin/sh\nexit 0\n' > "$homebrew_zsh_dir/$tool"
  chmod u+x "$homebrew_zsh_dir/$tool"
  saved_path="$PATH"
  PATH="$homebrew_zsh_dir:$PATH"
  _cc_run_probe stale_homebrew_zsh "$stale_copy" plant nobin
  PATH="$saved_path"
  line="$_cc_probe_out"
  [ "$line" = "$tool=none" ] \
    || _cc_fail "a Homebrew-style zsh prefix that also holds $tool leaked it back onto PATH (got: $line) - _cc_run_probe's zsh-dir append proves nothing"
  _cc_ok "a Homebrew zsh sharing its prefix with $tool does not leak the tool back onto PATH"

  # Faithfulness canary: prove the redirect above is not a dead no-op - point
  # the SAME mechanism at the DECOY prefix (which DOES hold brew + $tool) and
  # confirm zsh's own loop really adds it to $path. Without this, "stale"
  # passing could just mean the mutation broke the loop entirely rather than
  # that it correctly excludes an empty one.
  canary_copy="$work/prefix-canary-root"
  _cc_hermetic_prefix_copy "$canary_copy" "$decoy_prefix"
  saved_probe="$probe"
  probe="print \"commands=\${+commands[$tool]}\""
  _cc_run_probe prefix_canary "$canary_copy" noplant nobin
  line="$_cc_probe_out"
  probe="$saved_probe"
  [ "$line" = "commands=1" ] \
    || _cc_fail "prefix-loop redirect canary: pointing zshrc's brew-prefix loop at a prefix that DOES hold $tool did not make \$+commands[$tool] true (got: $line) - the stale fix above proves nothing"
  _cc_ok "the brew-prefix redirect mechanism is faithful (a populated prefix IS discovered)"

  # Can-fail proof: drop the source block, the probe MUST notice.
  copy="$work/mutant-root"
  mkdir -p "$copy"
  tar -C "$repo_root" -cf - . | tar -C "$copy" -xf -
  rm -rf "$copy/.git"
  python3 - "$copy/zsh/zshrc" "$tool" <<'PY'
import io, sys
p, tool = sys.argv[1], sys.argv[2]
s = io.open(p, encoding='utf-8').read()
old = '''if (( $+commands[%s] )) && [[ -r $XDG_CACHE_HOME/zsh/%s-completion.zsh ]]; then
  source "$XDG_CACHE_HOME/zsh/%s-completion.zsh"
fi
''' % (tool, tool, tool)
if s.count(old) != 1:
    sys.exit("mutation setup: the %s source block anchor moved (found %d)" % (tool, s.count(old)))
io.open(p, 'w', encoding='utf-8').write(s.replace(old, ''))
PY
  _cc_run_probe mutant "$copy" plant
  line="$_cc_probe_out"
  [ -s "$work/mutant/cache/zsh/zcompdump" ] \
    || _cc_fail "mutation: the mutated zshrc never ran (no compdump) - the probe measured a default shell"
  [ "$line" = "$tool=none" ] \
    || _cc_fail "mutation: dropping the $tool source block was NOT detected (got: $line) - this test proves nothing"
  _cc_ok "removing the $tool source block IS detected (this test can fail)"

  # A second mutant: remove ONLY the $+commands half of the guard, keep
  # [[ -r ]]. A stale cache with the binary absent must then get wrongly
  # registered - proving the "stale" assertion above depends on the
  # $+commands guard actually shipped in zshrc, not just on [[ -r ]].
  # F1: built on the SAME empty-prefix redirect as "stale" above (belt and
  # suspenders - this mutant's own removed guard already makes it independent
  # of $tool's PATH discoverability, but the ship-gate finding named this
  # probe too, and the redirect is harmless here either way).
  copy2="$work/mutant-nocommands-root"
  _cc_hermetic_prefix_copy "$copy2" "$empty_prefix"
  python3 - "$copy2/zsh/zshrc" "$tool" <<'PY'
import io, sys
p, tool = sys.argv[1], sys.argv[2]
s = io.open(p, encoding='utf-8').read()
old = 'if (( $+commands[%s] )) && [[ -r $XDG_CACHE_HOME/zsh/%s-completion.zsh ]]; then' % (tool, tool)
new = 'if [[ -r $XDG_CACHE_HOME/zsh/%s-completion.zsh ]]; then' % tool
if s.count(old) != 1:
    sys.exit("mutation setup: the %s guard anchor moved (found %d)" % (tool, s.count(old)))
io.open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
  _cc_run_probe mutant_nocommands "$copy2" plant nobin
  line="$_cc_probe_out"
  [ "$line" = "$tool=_$tool" ] \
    || _cc_fail "mutant (no \$+commands guard) was NOT registered with $tool absent (got: $line) - the \$+commands assertion above proves nothing"
  _cc_ok "removing the \$+commands guard alone IS detected (a stale cache then wrongly registers)"

  echo "PASS: ${tool}_completion_test ($_cc_pass assertions)"
}
