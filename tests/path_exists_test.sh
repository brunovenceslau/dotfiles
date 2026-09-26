#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for _path_exists, the existence/directory predicate zsh/zshenv
# defines for the GIT_CEILING_DIRECTORIES guard (see the comment above it in
# zsh/zshenv). tests/git_ceiling_test.sh covers that guard's own integration
# cases; this file covers _path_exists' own semantics only, including its
# test(1)-style `[-d] PATH` argument order, its rc-2 error contract, and that
# its local `target` variable never shadows zsh's PATH-tied `path` array.
#
# Each case sources the REAL zsh/zshenv (not a copy), so a regression there is
# what fails here. Hermetic: `env -i` with a scratch HOME and an empty PATH,
# every fixture under one mktemp dir.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ck() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail "$1: got [$2] want [$3]"; fi; }

if ! command -v zsh >/dev/null 2>&1; then
  if [ -n "${STRICT:-}" ]; then fail "zsh not installed and STRICT=1"; fi
  echo "SKIP: path_exists_test (zsh not installed; enforced in CI)"
  exit 0
fi
zsh_bin="$(command -v zsh)"

work="$(mktemp -d "${TMPDIR:-/tmp}/path_exists_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
empty="$work/emptybin"; mkdir -p "$empty"
fakehome="$work/home"; mkdir -p "$fakehome"   # no envs dir here: the ceiling guard no-ops

dir="$work/a-dir"; mkdir -p "$dir"
file="$work/a-file"; : > "$file"
spaced="$work/dir with spaces"; mkdir -p "$spaced"
unicode="$work/dir-世界"; mkdir -p "$unicode"
missing="$work/does-not-exist"
dangling="$work/dangling-symlink"; ln -s "$work/nowhere" "$dangling"
symlink_to_dir="$work/symlink-to-dir"; ln -s "$dir" "$symlink_to_dir"

# rc ARG... - the exit code _path_exists gives when called with exactly these
# arguments (zero or more), evaluated in a fresh, empty-PATH zsh so nothing on
# the tester's machine (or a previous case) can leak in.
rc() {
  env -i HOME="$fakehome" PATH="$empty" "$zsh_bin" -f -c "
    source '$repo_root/zsh/zshenv'
    _path_exists \"\$@\"
    exit \$?" _ "$@"
}

# --- table: DESCRIPTION | EXPECT_RC | ARG... ----------------------------------
t() { # DESC EXPECT ARG...
  local desc="$1" expect="$2" got=0
  shift 2
  rc "$@" && got=0 || got=$?
  ck "$desc" "$got" "$expect"
}

# -- valid calls: test(1) order, [-d] PATH -------------------------------------
t "directory, default (-e)"            0 "$dir"
t "directory, -d"                      0 -d "$dir"
t "regular file, default (-e)"         0 "$file"
t "regular file, -d (not a directory)" 1 -d "$file"
t "missing path, default (-e)"         1 "$missing"
t "missing path, -d"                   1 -d "$missing"
t "empty argument, default (-e)"       1 ""
t "empty argument, -d"                 1 -d ""
t "path with spaces, default (-e)"     0 "$spaced"
t "path with spaces, -d"               0 -d "$spaced"
t "path with unicode name, default (-e)" 0 "$unicode"
t "path with unicode name, -d"         0 -d "$unicode"
t "dangling symlink, default (-e)"     1 "$dangling"
t "dangling symlink, -d"               1 -d "$dangling"
t "symlink to a directory, default"    0 "$symlink_to_dir"
t "symlink to a directory, -d"         0 -d "$symlink_to_dir"

# -- rejected calls: rc 2, no output -------------------------------------------
t "no arguments at all"                2
t "-d given but PATH missing"          2 -d
t "lone operand starting with -, not a known flag" 2 -foo
t "unknown flag -f"                    2 -f "$file"
t "flag in trailing (wrong) position"  2 "$file" -d
t "two non-flag arguments"             2 "$file" "$spaced"
t "too many arguments"                 2 -d "$file" extra

# --- no output on stdout or stderr, valid AND rejected calls alike -----------
check_silent() { # LABEL ARG...
  local label="$1"; shift
  outfile="$work/out"; errfile="$work/err"
  env -i HOME="$fakehome" PATH="$empty" "$zsh_bin" -f -c "
    source '$repo_root/zsh/zshenv'
    _path_exists \"\$@\"" _ "$@" \
    >"$outfile" 2>"$errfile" || true
  ck "no stdout for $label" "$(wc -c <"$outfile" | tr -d ' ')" "0"
  ck "no stderr for $label" "$(wc -c <"$errfile" | tr -d ' ')" "0"
}
check_silent "directory"                "$dir"
check_silent "-d directory"             -d "$dir"
check_silent "regular file"             "$file"
check_silent "missing path"             "$missing"
check_silent "empty argument"           ""
check_silent "path with spaces"         "$spaced"
check_silent "dangling symlink"         "$dangling"
check_silent "symlink to a directory"   -d "$symlink_to_dir"
check_silent "no arguments"
check_silent "unknown flag"             -f "$file"
check_silent "too many arguments"       -d "$file" extra

# --- the local `target` never shadows zsh's PATH-tied `path` array -----------
# `local path` (zsh's array alias for $PATH - see zsh/functions.zsh:25-26 on
# `up`) assigns to the `path` array, and zsh syncs the command hash table to
# that assignment directly, not on some later rehash. A shadowing `local path`
# inside _path_exists would flush the `foo` entry hashed below; `local target`
# must not.
out="$(env -i HOME="$fakehome" PATH="/usr/bin:/bin" "$zsh_bin" -f -c "
  source '$repo_root/zsh/zshenv'
  hash foo=/bin/echo
  _path_exists /
  print -r -- \"\${commands[foo]:-flushed}\"")"
ck "_path_exists does not flush the command hash table" "$out" "/bin/echo"

echo "PASS: path_exists_test ($pass assertions)"
