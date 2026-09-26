# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# tests/lib/bsd_readlink.sh - a readlink that prints the macOS way, for the link
# tests. Sourced, never run: `make test` globs tests/*.sh only, not this dir.
#
# macOS/BSD readlink(1) is stat(1), whose addchar() appends the final newline
# only when the target does not already end in one, so a target "T<newline>"
# prints exactly like "T". GNU readlink always appends it. A link-target read
# that is exact on Linux can therefore still be inexact on a Mac; running the
# same assertion through this shim makes a Linux run catch it.
#
# bsd_readlink_shim DIR - write DIR/readlink (honors -n, like both userlands)
#   and prove it collapses the terminator, or fail: a shim that printed the GNU
#   way would make every "bsd" pass vacuous. It wraps the host's `readlink -n`,
#   which is exact on GNU, BSD and busybox alike.
# rl_with MODE CMD... - run CMD with the host readlink (MODE native) or the shim
#   (MODE bsd) first on PATH, then restore PATH. Returns CMD's status.
# rl_nl - a literal newline, for building and matching such targets.
#
# Bash 3.2 compatible, like the tests that source it.
# shellcheck shell=bash

rl_nl='
'
rl_shim_dir=""

bsd_readlink_shim() {
  local dir="$1" real probe
  real="$(command -v readlink)" || return 1
  mkdir -p "$dir" || return 1
  cat > "$dir/readlink" <<EOF
#!/bin/sh
nonl=
if [ "\$1" = -n ]; then nonl=1; shift; fi
t="\$("$real" -n "\$1" && printf x)" || exit 1
t="\${t%x}"
printf '%s' "\$t"
[ -n "\$nonl" ] || case "\$t" in *"$rl_nl") ;; *) printf '\n' ;; esac
EOF
  chmod u+x "$dir/readlink" || return 1
  probe="$dir/.probe"
  rm -f -- "$probe"; ln -s "x$rl_nl" "$probe" || return 1
  [ "$("$dir/readlink" "$probe"; printf x)" = "x${rl_nl}x" ] || return 1
  [ "$("$dir/readlink" -n "$probe"; printf x)" = "x${rl_nl}x" ] || return 1
  rm -f -- "$probe"
  rl_shim_dir="$dir"
}

rl_with() {
  local mode="$1" saved="$PATH" rc=0
  shift
  if [ "$mode" = bsd ]; then
    [ -n "$rl_shim_dir" ] || return 1
    PATH="$rl_shim_dir:$PATH"
  fi
  hash -r
  "$@" || rc=$?
  PATH="$saved"
  hash -r
  return "$rc"
}
