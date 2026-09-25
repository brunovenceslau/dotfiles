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
# Proves four things on a fixture built under umask 002:
#   (1) before hardening, compaudit really invokes getent (the fixture can fail);
#   (2) harden_plugin_perms leaves no group/other-writable path under zsh/plugins,
#       and compaudit no longer invokes getent;
#   (3) the `install` and `link` arms both call it (link is the arm an upgrade
#       re-enters after its submodule update);
#   (4) it succeeds SILENTLY under BSD argv parsing: macOS's chmod stops option
#       parsing at the first operand, so a `--` placed after the mode was read as
#       a file, chmod exited 1, and every install printed a false "could not
#       remove group/other write" warning. GNU getopt permutes argv and accepts
#       either order, and cases (1)-(3) could not see it: the function returns 0
#       whatever chmod does, and the tree WAS hardened. Only the warning shows it.
# Hermetic: mktemp fixture, a logging getent shim and a BSD-argv chmod shim first
# on PATH.
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

# (4) BSD argv parsing. POSIXLY_CORRECT=1 makes GNU chmod stop at the first
# operand the way BSD getopt does, but it cannot carry this case alone: uutils
# chmod (the default coreutils on Ubuntu 26.04) permutes argv and ignores the
# variable (measured 2026-09-25). So a shim applies POSIX utility-syntax
# guideline 9 and getopt() semantics on every host - options end at the first
# operand, so a later `--` is an operand, not a delimiter - and reacts the way
# macOS's chmod does: it reports the `--` as a missing file, still applies the
# mode to every other operand (on host 1 the warning printed yet no g+w/o+w
# path was left), and exits 1. The real chmod runs under POSIXLY_CORRECT=1, so
# a GNU host checks the call twice.
real_chmod="$(command -v chmod)" || fail "no chmod on PATH"
bsd="$work/bsd"; mkdir -p "$bsd"; clog="$work/chmod.log"
cat > "$bsd/chmod" <<SHIM
#!/bin/sh
echo "chmod \$*" >> "$clog"
# Rebuild argv without a misplaced \`--\`: append each kept word, then shift the
# originals away (the for list is expanded once, before the loop changes \$@).
n=\$# opts=1 bad=0
for a in "\$@"; do
  if [ "\$opts" = 1 ]; then
    case \$a in
      --)  opts=0; set -- "\$@" "\$a"; continue ;;
      -?*) set -- "\$@" "\$a"; continue ;;
    esac
  fi
  opts=0
  if [ "\$a" = "--" ]; then
    echo "chmod: --: No such file or directory" >&2; bad=1
  else
    set -- "\$@" "\$a"
  fi
done
shift "\$n"
rc=0; "$real_chmod" "\$@" || rc=\$?
[ "\$bad" = 0 ] || exit 1
exit "\$rc"
SHIM
chmod u+x "$bsd/chmod"
# The shim must treat the old shape the way macOS does - exit 1, yet the mode
# applied to the real path - or the case below proves nothing.
: > "$work/probe"; chmod g+w "$work/probe"
if "$bsd/chmod" -R go-w -- "$work/probe" 2>/dev/null; then
  fail "fixture: the BSD-argv chmod shim accepted 'chmod -R go-w -- path' (case would be vacuous)"
fi
[ -z "$(find "$work/probe" -perm -020 -print)" ] \
  || fail "fixture: the BSD-argv chmod shim skipped the other operands (macOS still applies the mode)"
chmod -R g+w "$fx/zsh/plugins"   # re-loosen what case (2) hardened
[ -n "$(writable)" ] || fail "fixture: could not re-loosen zsh/plugins for case 4"
: > "$clog"
err="$(PATH="$bsd:$PATH" POSIXLY_CORRECT=1 \
  bash -c '. "$1"; DOTFILES="$2"; harden_plugin_perms' _ "$installer" "$fx" 2>&1 >/dev/null)" \
  || fail "harden_plugin_perms returned non-zero under BSD argv parsing"
[ -s "$clog" ] || fail "harden_plugin_perms never reached the chmod shim (case would be vacuous)"
[ -z "$err" ] || fail "harden_plugin_perms warned under BSD argv parsing: $err"
[ -z "$(writable)" ] || fail "group/other-writable paths remain under BSD argv parsing: $(writable)"
pass=$((pass + 3))

echo "PASS: plugin_perms_test ($pass assertions)"
