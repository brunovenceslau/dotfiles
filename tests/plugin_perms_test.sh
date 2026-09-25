#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# install.sh's harden_plugin_perms: a clone or submodule checkout made under
# umask 002 leaves zsh/plugins group-writable, and zsh-completions/src sits on
# the shell's fpath. compinit's audit (compaudit) then forks `getent group` on
# the startup path (the fork the startup-fork-gate caught on such a checkout)
# and, on a shared group such as macOS `staff`, reports the dirs as insecure.
# Proves three things on a fixture built under umask 002:
#   (1) before hardening, compaudit really invokes getent (the fixture can fail);
#   (2) harden_plugin_perms leaves no group/other-writable path under zsh/plugins,
#       and compaudit no longer invokes getent;
#   (3) the `install` and `link` arms both call it (link is the arm an upgrade
#       re-enters after its submodule update).
# Hermetic: mktemp fixture, a logging getent shim first on PATH.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
installer="$repo_root/install.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0

if ! command -v zsh >/dev/null 2>&1; then
  if [ -n "${STRICT:-}" ]; then fail "zsh not installed and STRICT=1"; fi
  echo "SKIP: plugin_perms_test (zsh not installed; enforced in CI)"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/plugin_perms_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fx="$work/dotfiles"
( umask 002
  mkdir -p "$fx/zsh/plugins/zsh-completions/src"
  printf '#compdef demo\n' > "$fx/zsh/plugins/zsh-completions/src/_demo" )

shim="$work/shim"; mkdir -p "$shim"; log="$work/getent.log"
printf '#!/bin/sh\necho "getent $*" >> "%s"\n' "$log" > "$shim/getent"
chmod u+x "$shim/getent"
# fpath is the fixture dir ALONE: a host's own group-writable system fpath dir
# (/usr/local/share/zsh on some macs) must not decide this test either way.
# compaudit is loaded (+X) before fpath is narrowed, so it still resolves.
audit() {   # run compaudit over the fixture's fpath dir; getent calls land in $log
  : > "$log"
  PATH="$shim:$PATH" zsh -f -c 'autoload -Uz +X compaudit; fpath=("$1"); compaudit >/dev/null 2>&1; :' \
    _ "$fx/zsh/plugins/zsh-completions/src"
}
writable() { find "$fx/zsh/plugins" \( -perm -020 -o -perm -002 \) -print; }

# (1) the fixture reproduces the fork.
[ -n "$(writable)" ] || fail "fixture: umask 002 left nothing group-writable (umask ignored?)"
audit
[ -s "$log" ] || fail "fixture: compaudit did not invoke getent on a group-writable fpath dir (case would be vacuous)"
pass=$((pass + 1))

# (2) the real function, sourced from install.sh (its dispatch is guarded).
bash -c '. "$1"; DOTFILES="$2"; harden_plugin_perms' _ "$installer" "$fx" \
  || fail "harden_plugin_perms returned non-zero"
[ -z "$(writable)" ] || fail "group/other-writable paths remain under zsh/plugins: $(writable)"
audit
[ ! -s "$log" ] || fail "compaudit still invokes getent after hardening: $(cat "$log")"
pass=$((pass + 2))

# (3) wiring: both the install and the link arm call it.
for arm in install link; do
  awk -v arm="  $arm)" '$0 == arm { f = 1; next }
       f && /^  [a-z|* -]+\)$/ { f = 0 }
       f && /harden_plugin_perms/ { found = 1 }
       END { exit !found }' "$installer" \
    || fail "the $arm arm does not call harden_plugin_perms"
  pass=$((pass + 1))
done

echo "PASS: plugin_perms_test ($pass assertions)"
