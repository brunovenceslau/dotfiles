#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for zsh/restic.zsh, the restic-pass-cli / restic-op wrappers that
# docs/backup-restore.md and docs/shell-reference.md document:
#   * nothing is defined without restic on PATH;
#   * no repo argument -> usage on stderr, exit 2;
#   * an unknown repo -> "no such repo config", exit 1;
#   * a missing runner -> "<runner> not found", exit 1;
#   * a known repo -> exactly `<runner> run --env-file <dir>/<repo>.env --
#     restic <args...>`, with the runner's exit status passed through;
#   * completion offers the *.env basenames and nothing else.
# restic, pass-cli and op are stubs that record their argv, so no secret manager
# and no repository is ever touched. Hermetic: mktemp XDG_CONFIG_HOME and PATH.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ck() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail "$1: got [$2] want [$3]"; fi; }

if ! command -v zsh >/dev/null 2>&1; then
  if [ -n "${STRICT:-}" ]; then fail "zsh not installed and STRICT=1"; fi
  echo "SKIP: restic_wrappers_test (zsh not installed; enforced in CI)"
  exit 0
fi
zsh_bin="$(command -v zsh)"

work="$(mktemp -d "${TMPDIR:-/tmp}/restic_wrappers_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export XDG_CONFIG_HOME="$work/config" ZDOTDIR="$work/zdotdir" REPO="$repo_root"
mkdir -p "$XDG_CONFIG_HOME/restic" "$ZDOTDIR"
envdir="$XDG_CONFIG_HOME/restic"
printf 'RESTIC_PASSWORD="pass://vault/BACKUP/X"\n' > "$envdir/photos_b2.env"
printf 'RESTIC_PASSWORD="op://vault/BACKUP/X"\n'   > "$envdir/photos_op.env"
: > "$envdir/README.md"                             # not a *.env: never offered

# stub NAME RC - a recorder that appends "NAME argv" to $work/calls and exits RC.
stub() {
  mkdir -p "$work/bin"
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit %s\n' "$1" "$work" "$2" > "$work/bin/$1"
  chmod u+x "$work/bin/$1"
}
# rz CODE - run CODE in `zsh -f` after sourcing restic.zsh, with ONLY the stub
# dir on PATH. Prints "rc=<n>" last; stderr goes to $work/err.
rz() {
  : > "$work/calls"
  PATH="$work/bin" "$zsh_bin" -f -c "source \"\$REPO/zsh/restic.zsh\"; $1; print -r -- \"rc=\$?\"" 2>"$work/err"
}

# --- no restic on PATH: nothing is defined ------------------------------------
mkdir -p "$work/bin"
ck "no restic -> no wrappers" "$(rz 'print -n "${+functions[restic-pass-cli]}${+functions[restic-op]}"')" "00rc=0"

stub restic 0; stub pass-cli 7; stub op 5

# --- usage and lookup errors ---------------------------------------------------
ck "no repo -> exit 2" "$(rz 'restic-pass-cli')" "rc=2"
ck "no repo -> the documented usage line" "$(cat "$work/err")" "usage: pass-cli-backed wrapper <repo> [restic args...]"
head -1 "$work/err" > "$work/usages"
ck "restic-op, no repo -> exit 2" "$(rz 'restic-op')" "rc=2"
ck "restic-op, no repo -> the documented usage line" "$(cat "$work/err")" "usage: op-backed wrapper <repo> [restic args...]"
head -1 "$work/err" >> "$work/usages"
ck "empty repo name -> exit 2" "$(rz 'restic-op ""')" "rc=2"
head -1 "$work/err" >> "$work/usages"
ck "empty repo name -> generic usage plus the env directory" "$(cat "$work/err")" "usage: <wrapper> <repo> [restic args...]
available: $envdir/*.env"
ck "unknown repo -> exit 1" "$(rz 'restic-op nosuch snapshots')" "rc=1"
grep -q "no such repo config: $envdir/nosuch.env" "$work/err" \
  || fail "unknown repo: wrong message ($(cat "$work/err"))"
[ ! -s "$work/calls" ] || fail "an error path still invoked a runner: $(cat "$work/calls")"

# Doc drift: every `usage: ...` line the two docs quote must be one the code
# printed above, and each doc must quote at least one.
for doc in config/restic/README.md docs/shell-reference.md; do
  grep -oE '`usage: [^`]+`' "$repo_root/$doc" | tr -d '`' > "$work/doc_usages"
  [ -s "$work/doc_usages" ] || fail "$doc quotes no restic usage line"
  while IFS= read -r u; do
    grep -qxF -- "$u" "$work/usages" || fail "$doc quotes a usage line the code does not print: [$u]"
    pass=$((pass + 1))
  done < "$work/doc_usages"
done

# --- the runner argv, and its exit status passed through ------------------------
ck "restic-pass-cli passes pass-cli's status through" "$(rz 'restic-pass-cli photos_b2 snapshots --json')" "rc=7"
ck "restic-pass-cli argv" "$(cat "$work/calls")" \
  "pass-cli run --env-file $envdir/photos_b2.env -- restic snapshots --json"
ck "restic-op passes op's status through" "$(rz 'restic-op photos_op check')" "rc=5"
ck "restic-op argv" "$(cat "$work/calls")" "op run --env-file $envdir/photos_op.env -- restic check"

# --- a missing runner --------------------------------------------------------------
rm "$work/bin/op"
ck "restic-op without op -> exit 1" "$(rz 'restic-op photos_op snapshots')" "rc=1"
grep -q 'restic-op: op not found' "$work/err" || fail "missing op: wrong message ($(cat "$work/err"))"

# --- completion: the *.env basenames, nothing else -------------------------------
# compadd only exists inside a completion widget, so a stand-in prints the array
# _restic_repos hands it (the name after -a).
ck "completion offers the *.env basenames" \
  "$(rz 'compadd() { local -a r; r=( ${(P)${@[-1]}} ); print -n -- ${(o)r} }; _restic_repos')" \
  "photos_b2 photos_oprc=0"

echo "PASS: restic_wrappers_test ($pass assertions)"
