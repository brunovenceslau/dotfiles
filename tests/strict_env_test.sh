#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# STRICT reaches a Makefile recipe through the environment, never spliced into
# shell text: make exports a variable that came from its environment or its
# command line, and `$(STRICT)` pasted into a recipe turns a hostile value
# (a quote and a command) into code. Each recipe with a missing-tool branch
# runs here on a PATH that lacks the tool, with a STRICT value that would
# write a marker file if it were spliced: the recipe must fail closed on the
# NON-EMPTY value, say so, and leave no marker. Also pinned statically: no
# recipe line holds `$(STRICT)` (comments may name it).
set -euo pipefail
set -E
trap '_err_rc=$?; [ "${BASH_SUBSHELL:-0}" -ne 0 ] || echo "ERR: unexpected failure at line $LINENO (rc $_err_rc): $BASH_COMMAND" >&2' ERR

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mk="$repo_root/Makefile"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/strict_env_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM
export GIT_CEILING_DIRECTORIES="$work"

# --- static: no recipe line splices STRICT or TEST_JOBS -----------------------
# Both reach their readers through the environment (TEST_JOBS: the runner
# make test execs), so the same pin holds both.
# Every spelling make would expand into shell text: $(STRICT), ${STRICT},
# $(value STRICT), ${value STRICT} and a substitution reference such as
# $(STRICT:a=b). A `$` starts a reference only when an EVEN number of `$`
# precede it (`$$` is a literal dollar), so `x$$$(STRICT)` splices and
# `$$(STRICT)` does not; the regex consumes the preceding `$` in pairs.
# `$${STRICT:-}` (the shell's own read) is not a splice. Comment lines may
# name it.
splice_re='(^|[^$])(\$\$)*\$([({]|\([a-z]+ +|\{[a-z]+ +)(STRICT|TEST_JOBS)([)}]|:[^)}]*[)}])'
splices() { grep -nE -e "$splice_re" | grep -vE '^[0-9]+:[[:space:]]*#' || true; }
spliced="$(splices < "$mk")"
[ -z "$spliced" ] && ok || fail "a recipe splices STRICT or TEST_JOBS into shell text: $spliced"
# the pin must bite: each spelling is caught, the shell's own read is not
for form in '[ -n "$(STRICT)" ]' '[ -n "${STRICT}" ]' '[ -n "$(value STRICT)" ]' 'x$(STRICT)' \
  'x$(STRICT:a=b)' 'x${STRICT:%=%y}' 'x$$$(STRICT)' 'x$$$$$(STRICT)' 'x$$ $(STRICT)' \
  '[ -n "${value STRICT}" ]' 'x$(TEST_JOBS)' 'x${TEST_JOBS}' 'x$(value TEST_JOBS)'; do
  [ -n "$(printf '\t%s\n' "$form" | splices)" ] && ok || fail "the splice pin misses: $form"
done
# an even run of `$` is literal dollars, so none of these is a reference
for form in '[ -n "$${STRICT:-}" ]' 'x$$(STRICT)' 'x$$$$(STRICT)'; do
  [ -z "$(printf '\t%s\n' "$form" | splices)" ] && ok || fail "the splice pin flags a literal dollar: $form"
done

# --- behaviour: a PATH with the generic tools and none of the gated ones --------
stub="$work/stub"; mkdir -p "$stub"
for t in bash env find git grep awk sed cut head cat sort tr mktemp rm; do
  p="$(command -v "$t" 2>/dev/null || true)"
  case "$p" in /*) ln -s "$p" "$stub/$t" ;; esac
done
make_path="$(command -v make)"
mark="$work/spliced-marker"
hostile="1\" ]; : > $mark; [ \"1"

# run_make HOW TARGET [-f MK]: make TARGET on the stub PATH. HOW is `env` (STRICT
# in the environment), `cmdline` (STRICT=... on make's command line, as in
# `make local-ci STRICT=1`) or `unset`. Output in $out, exit code in $rc.
run_make() {
  local how="$1" target="$2"
  shift 2
  local -a skip=() args=()
  # lint's own recipe holds the shellcheck branch; its prerequisites are not
  # under test here (check-patterns needs find, py-syntax is its own target).
  [ "$target" != lint ] || skip=(-o check-patterns -o py-syntax)
  case "$how" in
    cmdline) args=("STRICT=$hostile") ;;
  esac
  rc=0
  if [ "$how" = env ]; then
    out="$(cd "$repo_root" && PATH="$stub" STRICT="$hostile" \
      env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u GNUMAKEFLAGS \
      "$make_path" -s "$@" ${skip[@]+"${skip[@]}"} "$target" 2>&1)" || rc=$?
  else
    out="$(cd "$repo_root" && PATH="$stub" \
      env -u STRICT -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u GNUMAKEFLAGS \
      "$make_path" -s "$@" ${skip[@]+"${skip[@]}"} "$target" ${args[@]+"${args[@]}"} 2>&1)" || rc=$?
  fi
}

# Targets whose missing-tool branch reads STRICT: shellcheck (in lint), reuse,
# gitleaks, and python3 (py-syntax, linkcheck, commit-identity).
for target in lint reuse gitleaks py-syntax linkcheck commit-identity; do
  for how in env cmdline; do
    rm -f "$mark"
    run_make "$how" "$target"
    [ ! -e "$mark" ] || fail "$target ($how): STRICT was spliced into shell text and ran its payload"
    [ "$rc" != 0 ] || fail "$target ($how): a missing tool under a non-empty STRICT must fail: $out"
    case "$out" in
      *"STRICT=1 - failing closed"*) ok ;;
      *) fail "$target ($how): a missing tool under a non-empty STRICT must say it fails closed: $out" ;;
    esac
  done
  # control: STRICT unset, the same missing tool is a loud skip, exit 0
  rm -f "$mark"
  run_make unset "$target"
  # lint goes on to the zsh pass after the skipped shellcheck, and the stub
  # PATH has no zsh, so only the warning is asserted for it.
  if [ "$target" = lint ]; then
    # The stub PATH has no zsh either, so make stops at the zsh pass (exit 2,
    # make's own error), after the skipped shellcheck: the exit code pins that
    # the skip did not itself fail the target.
    [ "$rc" = 2 ] && case "$out" in *"zsh"*"command not found"*) true ;; *) false ;; esac \
      || fail "lint (unset): the skipped shellcheck must leave only the missing zsh to fail it (exit 2), got $rc: $out"
  else
    [ "$rc" = 0 ] || fail "$target (unset): a missing tool without STRICT must skip with exit 0, got $rc: $out"
  fi
  case "$out" in
    *"skipping"*) ok ;;
    *) fail "$target (unset): a missing tool without STRICT must print the skipping warning: $out" ;;
  esac
  [ ! -e "$mark" ] || fail "$target (unset): the marker exists"
done

# The value is read as empty or non-empty, nothing else: an EMPTY STRICT (in
# the environment and on the command line alike) is unset, so the missing tool
# skips with exit 0; STRICT=0 is non-empty, so it is strict today and must fail
# closed (a "0" that quietly disabled the gate would be the unsafe reading).
for target in reuse gitleaks py-syntax linkcheck commit-identity; do
  for how in env-empty cmdline-empty env-zero cmdline-zero; do
    case "$how" in
      env-empty) val=""; mode=env ;;
      cmdline-empty) val=""; mode=cmdline ;;
      env-zero) val="0"; mode=env ;;
      cmdline-zero) val="0"; mode=cmdline ;;
    esac
    rc=0
    if [ "$mode" = env ]; then
      out="$(cd "$repo_root" && PATH="$stub" STRICT="$val" \
        env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u GNUMAKEFLAGS \
        "$make_path" -s "$target" 2>&1)" || rc=$?
    else
      out="$(cd "$repo_root" && PATH="$stub" \
        env -u STRICT -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u GNUMAKEFLAGS \
        "$make_path" -s "$target" "STRICT=$val" 2>&1)" || rc=$?
    fi
    case "$how" in
      *-empty)
        [ "$rc" = 0 ] && case "$out" in *"skipping"*) true ;; *) false ;; esac \
          && ok || fail "$target ($how): an empty STRICT must skip with exit 0 and a warning, got $rc: $out" ;;
      *-zero)
        [ "$rc" != 0 ] && case "$out" in *"STRICT=1 - failing closed"*) true ;; *) false ;; esac \
          && ok || fail "$target ($how): STRICT=0 is non-empty and must fail closed, got $rc: $out" ;;
    esac
  done
done

# A target-specific STRICT (here, a wrapper makefile assigning it to `reuse`)
# reaches the recipe only because the Makefile exports STRICT: without
# `export STRICT` the recipe would see it empty and skip with exit 0.
printf 'include %s/Makefile\nreuse: STRICT := 1\n' "$repo_root" > "$work/target-specific.mk"
rc=0
out="$(cd "$repo_root" && PATH="$stub" env -u STRICT -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u GNUMAKEFLAGS \
  "$make_path" -s -f "$work/target-specific.mk" reuse 2>&1)" || rc=$?
{ [ "$rc" != 0 ] && case "$out" in *"STRICT=1 - failing closed"*) true ;; *) false ;; esac; } \
  && ok || fail "a target-specific STRICT must reach the recipe (rc $rc): $out"

echo "PASS: strict_env_test ($pass assertions)"
