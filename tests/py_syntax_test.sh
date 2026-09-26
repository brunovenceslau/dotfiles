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

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
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

# --- Behaviour: run the REAL target against scratch git repositories ---------
work="$(mktemp -d "${TMPDIR:-/tmp}/py_syntax_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM

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

# --- SECURITY REGRESSION: a tracked symlink to a character device (e.g.
# /dev/zero) must be rejected by an os.stat()/S_ISREG check BEFORE the gate
# ever opens it - opening one blocks on an infinite read forever. Bounded by
# a PURE-BASH watchdog, never `timeout`/`gtimeout` - neither ships on every
# platform (macOS has neither by default), and adding either is a new
# dependency (ask first, never silently); a tool-availability SKIP would also
# be wrong here, since STRICT=1's rule is that a MISSING TOOL fails the
# suite, and this fixture must always run regardless. The gate is started as
# its own background PROCESS GROUP (`set -m`, restored right after
# backgrounding), polled for up to devzero_bound_s seconds, and - if still
# alive - killed by its NEGATIVE pid: the whole group, not just the wrapper
# subshell, since the actual hung python3 is a grandchild (subshell -> make
# -> recipe shell -> python3) that would otherwise survive as an orphan. A
# regression here fails the suite with a clear "hung" message instead of
# hanging it.
devzero_bound_s=5
r="$work/devzero"; git_repo "$r"
ln -s /dev/zero "$r/devzero.py"
git -C "$r" add devzero.py
: > "$work/_last_out"
set -m
(
  cd "$r" || exit 1
  exec >"$work/_last_out" 2>&1
  # Scrubbed the same way as run() above: a leaked MAKEFLAGS from an outer
  # `make ... STRICT=1` would otherwise outrank this STRICT="" and change
  # what gets reported once the stat() check rejects devzero.py.
  env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL STRICT="" PATH="$PATH" make -f "$mk" py-syntax
) &
devzero_pid=$!
set +m
devzero_elapsed_s=0
devzero_hung=0
while kill -0 "$devzero_pid" 2>/dev/null; do
  if [ "$devzero_elapsed_s" -ge "$devzero_bound_s" ]; then
    devzero_hung=1
    # `|| true` on BOTH: under `set -e`, a kill that finds the group already
    # gone (TERM alone killed it - default disposition is termination, no
    # handler installed anywhere in this chain) returns nonzero and would
    # otherwise abort this whole script right here, silently, before the
    # "HUNG" fail() below ever runs - the one failure mode this fixture must
    # not have. Measured: reproduced and fixed during development.
    kill -TERM -"$devzero_pid" 2>/dev/null || true
    sleep 1
    kill -KILL -"$devzero_pid" 2>/dev/null || true
    break
  fi
  sleep 1
  devzero_elapsed_s=$((devzero_elapsed_s + 1))
done
rc=0
wait "$devzero_pid" 2>/dev/null || rc=$?
if [ "$devzero_hung" = "1" ]; then
  fail "a tracked symlink to /dev/zero HUNG the gate for ${devzero_bound_s}s+ (stat check regression) instead of being rejected quickly"
fi
[ "$rc" != "0" ] && ok \
  || fail "a tracked symlink to /dev/zero must be rejected (stat check), not read or silently pass: rc=$rc $(last)"
case "$(last)" in
  *"devzero.py: not a regular file"*) ok ;;
  *) fail "a symlink to /dev/zero must be rejected as 'not a regular file': $(last)" ;;
esac

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

# --- a NUL byte in the source must fail with a clean message, never a raw
# traceback: compile() raises ValueError for this (not SyntaxError) on every
# supported Python version, and a bare `except SyntaxError` would let it
# through uncaught.
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
# A minimal stub PATH: `make`, `git`, `mktemp` and `rm` (the recipe's own
# dependencies besides python3 itself), deliberately no `python3`. `make`
# itself needs resolving too, since `PATH=... make ...` searches the OVERRIDDEN
# PATH for the command name, not the caller's own.
stubbin="$work/stubbin"; mkdir -p "$stubbin"
ln -s "$(command -v make)" "$stubbin/make"
ln -s "$(command -v git)" "$stubbin/git"
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
