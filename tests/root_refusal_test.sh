#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# install.sh refuses root for every subcommand, before it does anything else
# (_install_refuse_root). The uid comes from the absolute /usr/bin/id, so no
# case here simulates root through PATH or the environment: that is exactly
# what the check must not trust.
#   1. The decision, through a function seam: install.sh sourced in a subshell,
#      with _install_uid overridden to answer 0, 00, empty, or garbage, and
#      _install_id_bin pointed at a missing file. Static reads that the check
#      is called before any lib/ is sourced and that the shebang is /bin/bash.
#   2. A fake `id` first on PATH answering 0 does not refuse a normal user.
#   3. Real root through `sudo -n`, with a fake `id` answering a user uid and a
#      fake `bash` first on PATH and a planted ~/.local/bin/starship: every
#      subcommand exits 1 with the refusal, and nothing is written. It runs a
#      scratch copy of the working tree, never the checkout itself, so a
#      regression cannot leave root-owned files in the real .git. Skipped (a privilege skip,
#      exit 0 even under STRICT=1) where passwordless sudo is unavailable.
#
# Bash 3.2 compatible (no associative arrays, no mapfile, no ${var,,}).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
refusal="install: refusing to run as root - run it as the owning user; sudo is never needed here"
unknown="install: cannot tell who is running this (/usr/bin/id gave no uid) - refusing to run"

if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  echo "SKIP: root_refusal_test (running as root: install.sh cannot be sourced here)"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/root_refusal_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" \
  XDG_CACHE_HOME="$work/home/.cache" XDG_STATE_HOME="$work/home/.local/state"
mkdir -p "$HOME"

# --- 1. The decision, through the _install_uid seam ---------------------------
seam() {  # UID-ANSWER EXPECTED-RC EXPECTED-MESSAGE
  local rc=0 out
  out="$( ( . "$repo_root/install.sh"; eval "_install_uid() { printf '%s\n' '$1'; }"; _install_refuse_root ) 2>&1 )" || rc=$?
  [ "$rc" -eq "$2" ] || fail "seam uid [$1]: expected rc $2, got $rc: $out"
  [ -z "$3" ] || [ "$out" = "$3" ] || fail "seam uid [$1]: expected [$3], got [$out]"
}
seam 0 1 "$refusal"
seam 00 1 "$refusal"
seam "" 1 "$unknown"
seam "0x" 1 "$unknown"
seam "$(/usr/bin/id -u)" 0 ""
rc=0; out="$( ( . "$repo_root/install.sh"; _install_id_bin="$work/no-such-id"; _install_refuse_root ) 2>&1 )" || rc=$?
[ "$rc" -eq 1 ] && [ "$out" = "install: cannot tell who is running this ($work/no-such-id is missing) - refusing to run" ] \
  || fail "a missing id binary must fail closed (rc $rc): $out"

# The check is called, at top level, before any lib/ is sourced: the seam above
# proves the decision, this that it runs. A static read, so it holds without sudo.
call="$(grep -n '^_install_refuse_root || exit 1$' "$repo_root/install.sh" | cut -d: -f1 || true)"
first_lib="$(grep -n '^\. "\$DOTFILES/lib/' "$repo_root/install.sh" | sed -n 1p | cut -d: -f1 || true)"
[ -n "$call" ] || fail "install.sh no longer calls _install_refuse_root at top level"
[ -n "$first_lib" ] && [ "$call" -lt "$first_lib" ] || fail "the root check no longer runs before lib/ is sourced"
# `#!/usr/bin/env bash` would run the first bash on PATH before the check.
[ "$(sed -n 1p "$repo_root/install.sh")" = "#!/bin/bash" ] || fail "install.sh's shebang is not the absolute #!/bin/bash"

# --- 2. A fake `id` on PATH does not decide ------------------------------------
fake="$work/fakebin"; mkdir -p "$fake"
printf '#!/bin/sh\necho 0\n' > "$fake/id"; chmod u+x "$fake/id"
rc=0; out="$(PATH="$fake:$PATH" "$repo_root/install.sh" help 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "a fake id answering 0 on PATH refused a normal user (rc $rc): $out"
case "$out" in usage:*) ;; *) fail "help did not print its usage: $out" ;; esac

# --- 3. Real root through sudo -n -----------------------------------------------
if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
  echo "SKIP: root_refusal_test case 3 (no passwordless sudo here)"
  echo "PASS: root_refusal_test (cases 1-2)"
  exit 0
fi
# A copy of the working tree's tracked files (uncommitted edits included: tar
# reads the working tree), without the plugin submodules, which the refusal
# never reaches. The path is asserted to be scratch, not the checkout.
tree="$work/tree"; mkdir -p "$tree"
git -C "$repo_root" ls-files -z --cached --others --exclude-standard -- \
    install.sh lib zsh config bin packages ':(exclude)zsh/plugins' \
  | tar -C "$repo_root" --null -T - -cf - | tar -C "$tree" -xf -
target="$tree/install.sh"
case "$target" in "$work"/*) ;; *) fail "case 3 must run a scratch copy, not $target" ;; esac
cmp -s "$target" "$repo_root/install.sh" || fail "the scratch copy is not the working-tree install.sh"
# The fake id now answers this user's uid, so a guard that asked PATH would let
# root through; the fake bash is what an `env bash` shebang would run; the
# planted starship is what _cache_shell_inits would run.
printf '#!/bin/sh\necho %s\n' "$(/usr/bin/id -u)" > "$fake/id"
printf '#!/bin/sh\n: > "%s"\n' "$work/fake-bash-ran" > "$fake/bash"; chmod u+x "$fake/bash"
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\n: > "%s"\n' "$work/planted-ran" > "$HOME/.local/bin/starship"
chmod u+x "$HOME/.local/bin/starship"
printf 'secret\n' > "$HOME/.zsh_history"
stamp="$work/stamp"; : > "$stamp"
before="$(cd "$work" && find . -print | LC_ALL=C sort)"
# help first: a missing check shows there without running a writing arm as root.
for arm in help reseed-settings install link upgrade uninstall packages; do
  rc=0
  out="$(sudo -n env PATH="$fake:$PATH" HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    XDG_CACHE_HOME="$XDG_CACHE_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
    "$target" "$arm" 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] || fail "sudo $arm: root must be refused with exit 1 (got $rc): $out"
  [ "$out" = "$refusal" ] || fail "sudo $arm: expected only the refusal, got: $out"
  [ ! -e "$work/planted-ran" ] || fail "sudo $arm: a user's ~/.local/bin/starship ran as root"
  [ ! -e "$work/fake-bash-ran" ] || fail "sudo $arm: a bash from the user's PATH ran as root"
done
[ "$(cd "$work" && find . -print | LC_ALL=C sort)" = "$before" ] || fail "a refused root run changed the scratch tree"
[ -z "$(find "$work" "$repo_root" -path "$repo_root/.git" -prune -o -newer "$stamp" -user 0 -print 2>/dev/null)" ] \
  || fail "a refused root run left a root-owned file behind"

echo "PASS: root_refusal_test (cases 1-3, 7 subcommands under real root)"
