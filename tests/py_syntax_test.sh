#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Tests for the `make py-syntax` gate: python3 -I over every tracked and
# untracked-but-not-ignored .py file (Makefile), fed as a NUL-delimited list
# (git ls-files -z) read from STDIN, never argv - a shell word list breaks
# open on a space or a newline in a filename. Wiring is asserted statically
# (target exists, is a `lint` prerequisite, fails closed under STRICT=1);
# behaviour is asserted by running the real target against scratch git
# repositories, never the real tree.
set -euo pipefail
# `set -e` alone aborts on an unexpected failure without saying where. Name
# the line instead. errtrace (-E) carries the trap into functions; the
# BASH_SUBSHELL test keeps it out of $( ) and ( ) subshells, where bash 3.2
# fires ERR even when the caller checks the status (`x="$(cmd)" || rc=$?`).
# An unchecked subshell failure still surfaces at its caller's line.
set -E
trap '_err_rc=$?; [ "${BASH_SUBSHELL:-0}" -ne 0 ] || echo "ERR: unexpected failure at line $LINENO (rc $_err_rc): $BASH_COMMAND" >&2' ERR

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/bounded_run.sh
. "$repo_root/tests/lib/bounded_run.sh"
mk="$repo_root/Makefile"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); }

# --- Wiring: the target exists and is a `lint` prerequisite --------------------
grep -Eq '^py-syntax:' "$mk" || fail "Makefile has no 'py-syntax' target"
grep -qw py-syntax <<<"$(grep -E '^lint:' "$mk")" \
  || fail "py-syntax must be a 'lint' prerequisite, or 'make lint' before commit never runs it"
ok "Makefile defines a 'py-syntax' target that 'lint' depends on"

# --- Wiring: STRICT=1 fails closed on a missing python3 ------------------------
recipe="$(awk '/^py-syntax:/{p=1; next} /^[^\t]/{p=0} p' "$mk")"
[ -n "$recipe" ] || fail "could not read the 'py-syntax' target's recipe out of the Makefile"
grep -q 'STRICT' <<<"$recipe" \
  || fail "the 'py-syntax' recipe ignores STRICT - a missing python3 would skip even in CI"
grep -q 'exit 1' <<<"$recipe" \
  || fail "the 'py-syntax' recipe must exit 1 under STRICT=1 when python3 is absent"
ok "the 'py-syntax' recipe fails closed under STRICT=1 when python3 is absent"

# --- Wiring: a broken `git ls-files` always fails closed, never a skip --------
grep -q 'git ls-files' <<<"$recipe" || fail "the 'py-syntax' recipe does not call git ls-files"
grep -Eq 'git ls-files.*exit 1|exit 1.*git ls-files' <<<"$(printf '%s' "$recipe" | tr '\n' ' ')" \
  || fail "a 'git ls-files' failure must exit 1 unconditionally (not folded into the STRICT skip)"
ok "a 'git ls-files' failure fails closed regardless of STRICT"

# --- Wiring: the open-time checks no fixture can reach. They guard a swap of
# the path between the checks and the open (a race), and every staged swap
# is already refused by an earlier name-based check, so a mutant dropping one
# of them passes every behavioural fixture. Pinned by text instead: the open
# is non-blocking (a FIFO swapped in cannot hang it) and does not follow a
# final symlink, and the open descriptor is held to the device and inode
# the stat saw.
for pin in 'os.O_NONBLOCK' 'os.O_NOFOLLOW' '(fst.st_dev, fst.st_ino) != (st.st_dev, st.st_ino)'; do
  grep -qF -- "$pin" <<<"$recipe" \
    || fail "the 'py-syntax' recipe lost '$pin' - its open-time race guard is gone"
done
ok "the py-syntax open is non-blocking, no-follow, and held to the stat's device and inode"

# --- Behaviour: run the REAL target against scratch git repositories ---------
work="$(mktemp -d "${TMPDIR:-/tmp}/py_syntax_test.XXXXXX")"
# A signal trap that only cleaned up would let the script carry on with
# $work gone; exiting runs the EXIT trap once. A bounded_run group still
# alive at that point is reaped by its own sentinel (tests/lib/bounded_run.sh).
trap 'rm -rf "$work"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Pin the "outside a git repository" fixture below to actually BE outside one:
# without a ceiling, `git -C <nonrepo>` walks up its parent directories, so the
# fixture would pass only by the accident of $TMPDIR not sitting inside a real
# checkout. $work itself has no .git, so the walk stops there empty-handed.
export GIT_CEILING_DIRECTORIES="$work"

# run DIR [STRICT_VAL] [PATH_VAL] -> echo exit code; stdout+stderr land in
# $work/_last_out (last() reads it back), OVERWRITTEN fresh each call. PATH_VAL
# defaults to the real PATH (python3 available); pass a stub to simulate
# python3 missing. -f points at THIS repo's Makefile throughout, so only the
# git/python3 CONTEXT changes across calls, never the gate's own logic.
# `env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL` scrubs the inherited make state
# BEFORE re-setting STRICT: under `make local-ci STRICT=1` (this suite's own
# real CI invocation, and `MAKEFLAGS='STRICT=1' bash tests/py_syntax_test.sh`
# below reproduces it without CI), the outer make exports STRICT=1 as a
# command-line variable through MAKEFLAGS, and a MAKEFLAGS command-line
# assignment OUTRANKS a same-named environment variable in the nested make
# below - so `STRICT="$strict" ... make -f "$mk" py-syntax` alone would still
# see STRICT=1 even when $strict is "", making the "without STRICT" fixtures
# silently inherit fail-closed behaviour. Scrubbing MAKEFLAGS/MFLAGS makes the
# nested make read STRICT from this call's own environment only; MAKELEVEL is
# scrubbed alongside since it travels the same inherited-make-state path.
run() {
  local dir="$1" strict="${2:-}" path="${3:-$PATH}" rc=0
  (cd "$dir" && env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL \
    STRICT="$strict" PATH="$path" make -f "$mk" py-syntax) \
    > "$work/_last_out" 2>&1 || rc=$?
  echo "$rc"
}
last() { cat "$work/_last_out"; }

# --- lint parses tests/lib/*.sh with /bin/bash -n too: the sourced helpers
# never run on their own, so a syntax error there would otherwise surface
# only as a confusing failure in each suite that sources them. The real lint
# target runs in a scratch tree holding one valid test and one lib file,
# with its check-patterns and py-syntax prerequisites held back (`-o`), so
# only the parse passes run. A valid lib file is the positive control.
lp="$work/lintparse"; mkdir -p "$lp/tests/lib"
printf 'true\n' > "$lp/tests/ok_test.sh"
lint_parse() {
  local rc=0
  (cd "$lp" && env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL STRICT="" \
    make -f "$mk" -o check-patterns -o py-syntax lint) > "$work/_last_out" 2>&1 || rc=$?
  echo "$rc"
}
printf 'true\n' > "$lp/tests/lib/helper.sh"
[ "$(lint_parse)" = "0" ] && ok || fail "lint's parse step must pass a valid tests/lib file: $(last)"
case "$(last)" in
  *"/bin/bash -n tests/lib/helper.sh"*) ok ;;
  *) fail "lint must parse tests/lib/*.sh with /bin/bash -n: $(last)" ;;
esac
printf 'if true; then\n' > "$lp/tests/lib/helper.sh"
[ "$(lint_parse)" != "0" ] && ok || fail "an unterminated 'if' in tests/lib/*.sh must fail lint's parse step: $(last)"

git_repo() {  # git_repo DIR - a minimal scratch git repo, gpgsign off
  mkdir -p "$1"
  git init -q "$1"
  git -C "$1" config user.email a@x
  git -C "$1" config user.name a
  git -C "$1" config commit.gpgsign false
}

# a valid tracked .py file passes, and leaves no __pycache__ behind
r="$work/valid"; git_repo "$r"
printf 'x = 1\n' > "$r/good.py"
git -C "$r" add good.py
[ "$(run "$r")" = "0" ] && ok || fail "a valid tracked .py file must pass: $(last)"
[ ! -e "$r/__pycache__" ] && ok || fail "py-syntax must not leave a __pycache__ behind"

# a syntax error in a tracked .py file fails, naming the file
r="$work/broken"; git_repo "$r"
printf 'def broken(:\n    pass\n' > "$r/bad.py"
git -C "$r" add bad.py
rc="$(run "$r")"
[ "$rc" != "0" ] && ok || fail "a tracked .py file with a syntax error must fail the gate"
case "$(last)" in
  *bad.py*) ok ;;
  *) fail "the failure must name the offending file: $(last)" ;;
esac

# an UNTRACKED (never `git add`ed) .py file with a syntax error is STILL caught -
# the gate scans by wildcard-like reach (tracked + untracked-not-ignored), the
# same way the other lint passes above it scan by filesystem wildcard, not by
# git tracking state; a new .py file is caught before its first commit.
r="$work/untracked"; git_repo "$r"
printf 'def broken(:\n    pass\n' > "$r/untracked.py"
[ "$(run "$r")" != "0" ] && ok || fail "an untracked (not staged) .py file with a syntax error must still fail"

# a GITIGNORED .py file with a syntax error is NOT caught - --exclude-standard
# means the gate never even looks at it, same as git ls-files itself would not.
r="$work/ignored"; git_repo "$r"
printf 'ignored.py\n' > "$r/.gitignore"
printf 'def broken(:\n    pass\n' > "$r/ignored.py"
[ "$(run "$r")" = "0" ] && ok || fail "a gitignored .py file with a syntax error must NOT fail the gate"

# --- SECURITY REGRESSION: a space in a filename must not word-split into two
# argv entries. A word-split file list would open "good" and "file.py"
# (decoys, both valid) instead of "good file.py" (the real, broken file) and
# PASS. Decoys are gitignored so they never appear in the file list under
# their own name either - only the space bypass could reach them.
r="$work/space-in-name"; git_repo "$r"
printf 'def broken(:\n    pass\n' > "$r/good file.py"
git -C "$r" add "good file.py"
printf 'good\nfile.py\n' > "$r/.gitignore"
printf 'x = 1\n' > "$r/good"
printf 'x = 1\n' > "$r/file.py"
rc="$(run "$r")"
[ "$rc" != "0" ] && ok || fail "a space in a tracked .py filename must not be word-split into decoy files (bypass regression)"
case "$(last)" in
  *"good file.py"*) ok ;;
  *) fail "the failure must name the real file 'good file.py', not a word-split decoy: $(last)" ;;
esac

# --- SECURITY REGRESSION: a newline in a filename must not escape through
# git's default (non -z) C-quoted output. `-z` leaves it NUL-delimited and
# unquoted; the gate must still open exactly this file and report a clean
# failure, never silently pass and never crash.
r="$work/newline-in-name"; git_repo "$r"
nlfile=$'weird\nname.py'
(cd "$r" && printf 'def broken(:\n    pass\n' > "$nlfile" && git add -- "$nlfile")
rc="$(run "$r")"
[ "$rc" != "0" ] && ok || fail "a newline embedded in a tracked .py filename must still fail the gate"
case "$(last)" in
  *Traceback*) fail "a newline in a filename must not crash the gate with a Python traceback: $(last)" ;;
  *) ok ;;
esac
case "$(last)" in
  *weird*) ok ;;
  *) fail "the failure must name the real file (containing 'weird'), not stay silent about which one: $(last)" ;;
esac

# --- SECURITY REGRESSION: a tracked symlink to a special file must be
# rejected by the os.stat()/S_ISREG check BEFORE the gate opens it. Two
# fixtures, because they hang differently: /dev/zero reads forever (the capped
# read now stops that one even without the S_ISREG check, at the size cap),
# while opening a FIFO blocks until a writer appears, which here is never - a
# real hang, and the one fixture that proves the S_ISREG check itself. Each
# runs under bounded_run (tests/lib/bounded_run.sh): its own process group,
# killed whole after gate_bound_s seconds, so a regression fails the suite
# with a "HUNG" message instead of hanging it. The FIFO sits inside the repo,
# gitignored, so the symlink passes the realpath check and only S_ISREG stands
# between the gate and the blocking open().
gate_bound_s=5
# gate_in DIR - the gate from DIR, scrubbed the same way as run() above: a
# leaked MAKEFLAGS from an outer `make ... STRICT=1` would otherwise outrank
# this STRICT="" and change what gets reported.
gate_in() {
  cd "$1" && env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL STRICT="" PATH="$PATH" make -f "$mk" py-syntax
}
# special_fixture WHAT STEM - assert the gate rejects $r/STEM.py (a symlink to
# WHAT) quickly, as 'not a regular file'.
special_fixture() {
  : > "$work/_last_out"
  bounded_run "$gate_bound_s" "$work/_last_out" gate_in "$r"
  [ "$br_stuck" = 0 ] \
    || fail "the gate on a tracked symlink to $1 survived SIGKILL and could not be reaped"
  [ "$br_hung" = 0 ] \
    || fail "a tracked symlink to $1 HUNG the gate for ${gate_bound_s}s+ (stat check regression) instead of being rejected quickly: $(last)"
  [ "$br_rc" != "0" ] && ok \
    || fail "a tracked symlink to $1 must be rejected (stat check), not read or silently pass: rc=$br_rc $(last)"
  case "$(last)" in
    *"$2.py: not a regular file"*) ok ;;
    *) fail "a symlink to $1 must be rejected as 'not a regular file': $(last)" ;;
  esac
}
r="$work/fifo"; git_repo "$r"
mkfifo "$r/pipe"
printf 'pipe\n' > "$r/.gitignore"
ln -s pipe "$r/fifo.py"
git -C "$r" add fifo.py .gitignore
special_fixture "a FIFO" fifo

r="$work/devzero"; git_repo "$r"
ln -s /dev/zero "$r/devzero.py"
git -C "$r" add devzero.py
special_fixture /dev/zero devzero

# --- SECURITY REGRESSION: a tracked symlink resolving OUTSIDE the repository
# root must not be read transparently - the gate would otherwise syntax-check
# and report on a file the repo does not own. The target is a real, valid,
# readable .py file created fresh under THIS TEST's own scratch tree ($work),
# a sibling of the fixture's repo root ($work/outside) rather than inside it -
# unlike a path such as /etc/hostname, this exists identically on every OS (a
# previous version dangled on macOS, which ships no /etc/hostname, giving a
# platform-dependent rejection reason instead of the one under test). The
# message is asserted to be the REALPATH check specifically, not merely "any
# rejection" - a dangling symlink (below) is rejected for a different reason
# and must not be conflated with this one.
r="$work/outside"; git_repo "$r"
printf 'x = 1\n' > "$work/outside_target.py"
ln -s "$work/outside_target.py" "$r/outside.py"
git -C "$r" add outside.py
rc="$(run "$r")"
[ "$rc" != "0" ] && ok || fail "a tracked symlink resolving outside the repo root must fail the gate, not be read"
case "$(last)" in
  *"outside.py: resolves outside the repository root"*) ok ;;
  *) fail "a symlink escaping the repo root must be rejected by the realpath check specifically: $(last)" ;;
esac

# --- a DANGLING symlink (its target does not exist, inside or outside the
# repo) is a DIFFERENT failure mode from "resolves outside": os.stat() itself
# raises OSError before the realpath check ever runs. Proven on its own so
# the two paths are never conflated - a fixture pointing at a real file
# (above) cannot exercise this one, and vice versa.
r="$work/dangling"; git_repo "$r"
ln -s "$work/does-not-exist-$$.py" "$r/dangling.py"
git -C "$r" add dangling.py
rc="$(run "$r")"
[ "$rc" != "0" ] && ok || fail "a dangling symlink must fail the gate, not pass silently"
case "$(last)" in
  *"dangling.py"*"resolves outside the repository root"*) \
    fail "a dangling symlink must be rejected by the stat()/OSError path, not misreported as 'resolves outside': $(last)" ;;
  *"dangling.py"*) ok ;;
  *) fail "the failure must name the dangling symlink: $(last)" ;;
esac

# --- SECURITY REGRESSION: a tracked symlink resolving INTO a git directory
# must not be read: the git dir holds config, hooks and objects, none of them
# the repo's Python. Three fixtures, one per way the gate recognises a git
# dir, each asserting the git-dir message specifically (plus a fourth below):
#   - the checkout's own .git (the device/inode match AND the `.git`
#     component match both see it);
#   - an untracked nested repository's .git, which is none of the dirs
#     `rev-parse` names: only the `.git` component match sees it;
#   - a separate git dir under another name inside the checkout (`git init
#     --separate-git-dir`): no `.git` component, only the device/inode match
#     against the git dir `rev-parse` named sees it.
# gitdir_fixture NAME TARGET - track $r/NAME.py -> TARGET and assert the
# git-dir rejection.
gitdir_fixture() {
  ln -s "$2" "$r/$1.py"
  git -C "$r" add "$1.py"
  rc="$(run "$r")"
  [ "$rc" != "0" ] && ok || fail "a tracked symlink into a git dir ($2) must fail the gate, not be read"
  case "$(last)" in
    *"$1.py: resolves into a git directory"*) ok ;;
    *) fail "a symlink into a git dir ($2) must be rejected by the git-dir check specifically: $(last)" ;;
  esac
}
r="$work/into-git"; git_repo "$r"
gitdir_fixture hook .git/config

r="$work/into-nested"; git_repo "$r"
git_repo "$r/nested"
printf 'nested/\n' > "$r/.gitignore"
git -C "$r" add .gitignore
gitdir_fixture nested nested/.git/config

r="$work/into-separate"; mkdir -p "$r"
git init -q --separate-git-dir="$r/gitdata" "$r"
git -C "$r" config commit.gpgsign false
printf 'gitdata/\n' > "$r/.gitignore"
git -C "$r" add .gitignore
gitdir_fixture sep gitdata/config

# - an untracked nested repository whose .git is a GITFILE pointing at a git
#   dir under another name: no `.git` component on the path, and not a git
#   dir `rev-parse` named for the outer checkout; only the git-dir SHAPE
#   check (HEAD plus objects/ and refs/) sees it.
r="$work/into-gitfile"; git_repo "$r"
git init -q --separate-git-dir="$r/sub/gd" "$r/sub"
printf 'sub/\n' > "$r/.gitignore"
git -C "$r" add .gitignore
gitdir_fixture gf sub/gd/config

# --- REGRESSION: the gate scans the whole checkout from any subdirectory.
# `git ls-files` lists only the current subtree, so a run from sub/ once
# checked sub/ alone and passed with a broken file at the top level.
r="$work/subdir"; git_repo "$r"
mkdir -p "$r/sub"
printf 'x = 1\n' > "$r/sub/ok.py"
printf 'def broken(:\n    pass\n' > "$r/top_bad.py"
git -C "$r" add sub/ok.py top_bad.py
rc="$(run "$r/sub")"
[ "$rc" != "0" ] && ok || fail "a run from a subdirectory must still scan the whole checkout and fail on top_bad.py: $(last)"
# The syntax error itself, not a lookup failure: paths are joined to the
# toplevel, so a gate that listed from the toplevel but opened relative to the
# subdirectory would also name top_bad.py, as missing.
case "$(last)" in
  *"No such file"*) fail "a run from a subdirectory must open the listed paths from the toplevel: $(last)" ;;
  *"top_bad.py: "*"(top_bad.py, line 1)"*) ok ;;
  *) fail "a run from a subdirectory must report top_bad.py's syntax error: $(last)" ;;
esac

# --- REGRESSION: a leaked git env var cannot steer the gate. A hook or a
# `git rebase --exec` running `make lint` leaks GIT_DIR/GIT_WORK_TREE; the
# gate unsets git's local env vars (GIT_ENV_SCRUB) before its first git call.
#   - GIT_DIR+GIT_WORK_TREE aimed at a clean decoy repo: without the scrub the
#     gate lists and checks the decoy and passes over the broken file here;
#   - GIT_DIR alone, from a subdirectory: git then takes the current
#     directory as the toplevel, bringing back the subset scan S3 closed.
decoy="$work/decoy"; git_repo "$decoy"
printf 'x = 1\n' > "$decoy/fine.py"
git -C "$decoy" add fine.py
r="$work/leak"; git_repo "$r"
mkdir -p "$r/sub"
printf 'x = 1\n' > "$r/sub/ok.py"
printf 'def broken(:\n    pass\n' > "$r/leak_bad.py"
git -C "$r" add sub/ok.py leak_bad.py
rc="$(GIT_DIR="$decoy/.git" GIT_WORK_TREE="$decoy" run "$r")"
[ "$rc" != "0" ] && ok || fail "a leaked GIT_DIR/GIT_WORK_TREE must not steer the gate at another tree: $(last)"
case "$(last)" in
  *"leak_bad.py"*) ok ;;
  *) fail "under a leaked GIT_WORK_TREE the gate must still report this checkout's leak_bad.py: $(last)" ;;
esac
rc="$(GIT_DIR="$r/.git" run "$r/sub")"
[ "$rc" != "0" ] && ok || fail "a leaked GIT_DIR from a subdirectory must not shrink the scan to that subdirectory: $(last)"
case "$(last)" in
  *"leak_bad.py"*) ok ;;
  *) fail "under a leaked GIT_DIR from sub/ the gate must still report leak_bad.py: $(last)" ;;
esac

# --- a git older than 2.31 does not reject --path-format=absolute: it
# echoes it back as one more output line and exits 0 with an empty stderr.
# Staged with a stub git ahead of the real one that answers that one call
# the old way; the gate must fail closed on the line count and name the
# version it needs.
oldgit="$work/oldgit"; mkdir -p "$oldgit"
printf '#!/bin/sh\nif [ "$1" = rev-parse ] && [ "$2" = --path-format=absolute ]; then\n  echo "$2"; shift 2; exec "%s" rev-parse "$@"\nfi\nexec "%s" "$@"\n' \
  "$(command -v git)" "$(command -v git)" > "$oldgit/git"
chmod u+x "$oldgit/git"
r="$work/oldgit-repo"; git_repo "$r"
printf 'x = 1\n' > "$r/good.py"
git -C "$r" add good.py
rc="$(run "$r" "" "$oldgit:$PATH")"
[ "$rc" != "0" ] && ok || fail "a git that echoes --path-format=absolute back (pre-2.31) must fail the gate closed: $(last)"
case "$(last)" in
  *"needs git 2.31 or later"*) ok ;;
  *) fail "the pre-2.31 failure must name the git version the gate needs: $(last)" ;;
esac

# --- the size cap: a file larger than PY_SYNTAX_MAX_BYTES is refused before
# it is read, with a message naming the cap; a file of exactly that size is
# still read and checked. Both are valid Python (a single comment line), so
# only the size decides. The cap is read from the Makefile, so a change there
# moves the fixtures with it.
cap="$(sed -n 's/^PY_SYNTAX_MAX_BYTES := //p' "$mk")"
case "$cap" in
  ''|*[!0-9]*) fail "could not read PY_SYNTAX_MAX_BYTES out of the Makefile: '$cap'" ;;
esac
# comment_file PATH SIZE - a SIZE-byte file holding one Python comment line.
comment_file() {
  { printf '#'; head -c "$(($2 - 2))" /dev/zero | tr '\0' a; printf '\n'; } > "$1"
}
r="$work/size"; git_repo "$r"
comment_file "$r/at_cap.py" "$cap"
git -C "$r" add at_cap.py
[ "$(wc -c < "$r/at_cap.py" | tr -d ' ')" = "$cap" ] || fail "test bug: at_cap.py is not exactly $cap bytes"
rc="$(run "$r")"
[ "$rc" = "0" ] && ok || fail "a valid .py file of exactly $cap bytes must pass: $(last)"
comment_file "$r/over_cap.py" "$((cap + 1))"
git -C "$r" add over_cap.py
rc="$(run "$r")"
[ "$rc" != "0" ] && ok || fail "a .py file larger than $cap bytes must fail the gate"
case "$(last)" in
  *"over_cap.py: larger than $cap bytes"*) ok ;;
  *) fail "a .py file over the cap must be refused with the size message: $(last)" ;;
esac

# --- a NUL byte in the source must fail with a clean message, never a raw
# traceback: compile() raises SyntaxError for it on Python 3.12 and later but
# ValueError on 3.11 and earlier, and a bare `except SyntaxError` would let
# the older one through uncaught. Only the python3 on PATH is exercised here.
r="$work/nulbyte"; git_repo "$r"
printf 'x = 1\x00\n' > "$r/nulbyte.py"
git -C "$r" add nulbyte.py
rc="$(run "$r")"
[ "$rc" != "0" ] && ok || fail "a NUL byte in a tracked .py file must fail the gate"
case "$(last)" in
  *Traceback*) fail "a NUL byte must fail with a clean message, not a raw traceback: $(last)" ;;
  *"nulbyte.py"*) ok ;;
  *) fail "the failure must name the file holding the NUL byte: $(last)" ;;
esac

# --- SECURITY REGRESSION: `git ls-files` can exit 0 while WARNING on stderr
# (e.g. an unreadable subdirectory it could not open) - files under it are
# silently missing from the listing, which the gate must treat as a broken
# invocation, not a clean empty result. Skipped when running as root, since
# root ignores directory permission bits and the warning never fires.
if [ "$(id -u)" != "0" ]; then
  r="$work/noperm"; git_repo "$r"
  mkdir -p "$r/noperm"
  printf 'def broken(:\n    pass\n' > "$r/noperm/secret.py"
  chmod 000 "$r/noperm"
  rc="$(run "$r")"
  chmod 755 "$r/noperm"
  [ "$rc" != "0" ] && ok || fail "a 'git ls-files' stderr warning (unreadable directory) must fail the gate closed"
  case "$(last)" in
    *"could not open directory"*) ok ;;
    *) fail "the failure must surface git's own warning text: $(last)" ;;
  esac
else
  echo "SKIP: running as root - the unreadable-directory / git-ls-files-warning fixture cannot be staged"
fi

# --- a file `git ls-files` still lists but that is gone from disk (staged,
# then deleted without `git rm`) must fail with a clean OSError message,
# never a traceback, and never a silent pass.
r="$work/listed-missing"; git_repo "$r"
printf 'x = 1\n' > "$r/gone.py"
git -C "$r" add gone.py
rm -f "$r/gone.py"
rc="$(run "$r")"
[ "$rc" != "0" ] && ok || fail "a listed-but-missing .py file must fail the gate, not pass silently"
case "$(last)" in
  *Traceback*) fail "a listed-but-missing file must fail with a clean message, not a traceback: $(last)" ;;
  *"gone.py"*) ok ;;
  *) fail "the failure must name the missing file: $(last)" ;;
esac

# no .py files at all: a clean no-op, not a failure
r="$work/none"; git_repo "$r"
printf 'noop\n' > "$r/README"
git -C "$r" add README
rc="$(run "$r")"
[ "$rc" = "0" ] && ok || fail "a tree with no .py files at all must pass (a no-op, not a failure)"
case "$(last)" in
  *"no .py files"*) ok ;;
  *) fail "a tree with no .py files should say so: $(last)" ;;
esac

# --- Behaviour: python3 absent - skip without STRICT, fail WITH STRICT --------
# A minimal stub PATH: `make`, `git`, `grep`, `mktemp` and `rm` (the recipe's
# own dependencies besides python3 itself; grep checks git's env var list), deliberately no `python3`. `make`
# itself needs resolving too, since `PATH=... make ...` searches the OVERRIDDEN
# PATH for the command name, not the caller's own.
stubbin="$work/stubbin"; mkdir -p "$stubbin"
ln -s "$(command -v make)" "$stubbin/make"
ln -s "$(command -v git)" "$stubbin/git"
ln -s "$(command -v grep)" "$stubbin/grep"
ln -s "$(command -v mktemp)" "$stubbin/mktemp"
ln -s "$(command -v rm)" "$stubbin/rm"
r="$work/nopython"; git_repo "$r"
printf 'x = 1\n' > "$r/good.py"
git -C "$r" add good.py

rc="$(run "$r" "" "$stubbin")"
[ "$rc" = "0" ] && ok || fail "a missing python3 without STRICT must SKIP (exit 0), not fail: $(last)"
case "$(last)" in
  *"WARN"*"python3"*) ok ;;
  *) fail "a missing python3 without STRICT must warn: $(last)" ;;
esac

rc="$(run "$r" "1" "$stubbin")"
[ "$rc" != "0" ] && ok || fail "a missing python3 under STRICT=1 must FAIL the gate"
case "$(last)" in
  *"ERROR"*"python3"*) ok ;;
  *) fail "a missing python3 under STRICT=1 must say so: $(last)" ;;
esac

# --- REGRESSION GUARD: a leaked MAKEFLAGS from an outer `make ... STRICT=1`
# must not override the STRICT="" this call passes explicitly. This is
# exactly what `make local-ci STRICT=1` (this repo's own real invocation of
# this suite) leaves in the environment: STRICT=1 as a command-line
# variable, which make re-exports through MAKEFLAGS to every nested make -
# reproduced here without CI by exporting MAKEFLAGS directly, the same
# ambient state `MAKEFLAGS='STRICT=1' bash tests/py_syntax_test.sh` sets for
# the whole suite. Without the env -u scrub in run() above, this call would
# wrongly take the STRICT=1 branch and FAIL instead of skipping.
export MAKEFLAGS='STRICT=1'
rc="$(run "$r" "" "$stubbin")"
unset MAKEFLAGS
[ "$rc" = "0" ] && ok \
  || fail "a leaked MAKEFLAGS='STRICT=1' must not override an explicit STRICT='' (missing python3 must still SKIP): $(last)"
case "$(last)" in
  *"WARN"*"python3"*) ok ;;
  *) fail "a missing python3 without STRICT must warn even with MAKEFLAGS='STRICT=1' leaked in: $(last)" ;;
esac

# --- Behaviour: `git ls-files` itself failing (no git repo at all) fails
# closed UNCONDITIONALLY - never folded into the STRICT-skip path above, since
# this is a broken invocation, not an absent optional tool. -----------------
r="$work/notgit"; mkdir -p "$r"
printf 'x = 1\n' > "$r/good.py"
rc="$(run "$r")"
[ "$rc" != "0" ] && ok || fail "py-syntax outside a git repository must fail closed, not silently pass"
rc="$(run "$r" "1")"
[ "$rc" != "0" ] && ok || fail "py-syntax outside a git repository must fail closed under STRICT too"

echo "PASS: py_syntax_test ($pass assertions)"
