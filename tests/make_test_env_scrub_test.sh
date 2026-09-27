#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Tests for the Makefile `test` recipe's git env scrub, and for the
# `test-env-scrub` static check that holds the recipe to it. A git hook or a
# `git rebase --exec` that runs `make test` hands every suite a GIT_DIR,
# GIT_WORK_TREE or GIT_INDEX_FILE, and each suite's own fixture `git` calls
# would then commit or configure into THAT repository. Behaviour is proven by
# running the real recipe, with TEST_FILES pointed at a probe suite, under a
# leaked GIT_DIR aimed at a scratch sentinel repository under $TMPDIR, never a
# real checkout. The probe is a fresh process, so what it sees is what a
# suite sees.
set -euo pipefail
set -E
trap '_err_rc=$?; [ "${BASH_SUBSHELL:-0}" -ne 0 ] || echo "ERR: unexpected failure at line $LINENO (rc $_err_rc): $BASH_COMMAND" >&2' ERR

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mk="$repo_root/Makefile"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/make_test_env_scrub.XXXXXX")"
trap 'rm -rf "$work"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# This file's OWN git calls must not follow a leaked GIT_DIR either: it runs
# under `make test`, but also by hand.
# shellcheck disable=SC2046  # word-splitting is the point: one name per word
unset $(git rev-parse --local-env-vars 2>/dev/null) 2>/dev/null || true
export GIT_CEILING_DIRECTORIES="$work"

# make_in DIR ARGS... - the real Makefile from DIR, stdout+stderr into
# $work/_last_out, echoing the exit code. Inherited make state is scrubbed
# (see run() in tests/py_syntax_test.sh): an outer `make local-ci STRICT=1`
# exports MAKEFLAGS, which would also carry its own command-line variables
# into this nested make. MAKEFILES would add a makefile ahead of -f.
make_in() {
  local dir="$1" rc=0
  shift
  (cd "$dir" && env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEFILES make "$@") \
    > "$work/_last_out" 2>&1 || rc=$?
  echo "$rc"
}
last() { cat "$work/_last_out"; }

# --- the probe suite: fails when any git local env var reached it, or when
# its own fixture repo is not where its git calls land. The names are
# hardcoded, not asked of git, so a broken scrub cannot also blind the probe.
probe="$work/probe_test.sh"
cat > "$probe" <<'EOF'
#!/usr/bin/env bash
set -eu
: > "$PROBE_MARK"
for v in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY; do
  if eval "[ -n \"\${$v+x}\" ]"; then echo "LEAK: $v reached the suite"; exit 3; fi
done
own="$PROBE_DIR/own"
git init -q "$own"
git -C "$own" config probe.touched yes
got="$(cd "$own" && git rev-parse --absolute-git-dir)"
[ "$got" -ef "$own/.git" ] || { echo "STEERED: git dir is $got, not $own/.git"; exit 4; }
echo "PROBE OK"
EOF

# A victim repository the leaked vars point at. Nothing may change in it.
victim="$work/victim"
git init -q "$victim"
git -C "$victim" config user.email a@x
git -C "$victim" config user.name a
git -C "$victim" config commit.gpgsign false
printf 'baseline\n' > "$victim/f"
git -C "$victim" add f
git -C "$victim" commit -qm baseline
victim_state() {
  printf '%s %s %s\n' "$(git -C "$victim" rev-parse HEAD)" \
    "$(cksum < "$victim/.git/config")" "$(cksum < "$victim/.git/index")"
}
before="$(victim_state)"

# --- positive control: the probe itself catches a leak. Without this, a
# probe that never looked would make the scrub assertions below vacuous.
rc=0
PROBE_MARK="$work/mark0" PROBE_DIR="$work/ctl" GIT_DIR="$victim/.git" \
  bash "$probe" > "$work/_last_out" 2>&1 || rc=$?
[ "$rc" = 3 ] && ok || fail "test bug: the probe must report a leaked GIT_DIR (rc $rc): $(last)"

# --- REGRESSION: a leaked GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE does not reach
# a suite `make test` runs, and cannot steer its git calls into the victim.
rm -f "$work/mark1"
rc="$(GIT_DIR="$victim/.git" GIT_WORK_TREE="$victim" GIT_INDEX_FILE="$victim/.git/index" \
  PROBE_MARK="$work/mark1" PROBE_DIR="$work/p1" \
  make_in "$work" -f "$mk" test TEST_FILES="$probe")"
[ -e "$work/mark1" ] || fail "test bug: the probe suite never ran under make test: $(last)"
[ "$rc" = 0 ] && ok || fail "a suite under 'make test' must not see a leaked GIT_DIR (rc $rc): $(last)"
case "$(last)" in
  *"PROBE OK"*) ok ;;
  *) fail "the probe suite must report a clean env and an unsteered git dir: $(last)" ;;
esac
[ "$before" = "$(victim_state)" ] && ok \
  || fail "a leaked GIT_DIR must leave the victim repository untouched (HEAD, config, index)"

# --- fail closed: the scrub list comes from git itself, so a git that
# answers with nothing, without GIT_DIR or GIT_INDEX_FILE, or with an error
# would strip nothing. Each is staged with a stub `git` ahead of the real one;
# the recipe must stop BEFORE any suite runs.
stub="$work/stub"; mkdir -p "$stub"
# stub_case NAME BODY - a stub git whose `rev-parse --local-env-vars` runs
# BODY (a sh snippet); anything else goes to the real git.
real_git="$(command -v git)"
stub_case() {
  printf '#!/bin/sh\nif [ "$1 $2" = "rev-parse --local-env-vars" ]; then %s; fi\nexec "%s" "$@"\n' \
    "$2" "$real_git" > "$stub/git"
  chmod u+x "$stub/git"
  rm -f "$work/mark-stub"
  rc="$(PATH="$stub:$PATH" PROBE_MARK="$work/mark-stub" PROBE_DIR="$work/p-$1" \
    make_in "$work" -f "$mk" test TEST_FILES="$probe")"
  [ "$rc" != 0 ] && ok || fail "make test must fail closed when git's env var list is $1: $(last)"
  [ ! -e "$work/mark-stub" ] && ok || fail "no suite may run when git's env var list is $1: $(last)"
  case "$(last)" in
    *"ERROR: 'git rev-parse --local-env-vars'"*) ok ;;
    *) fail "make test must say the env var list is unusable ($1): $(last)" ;;
  esac
}
stub_case empty 'exit 0'
stub_case "missing GIT_DIR" 'echo GIT_WORK_TREE; echo GIT_INDEX_FILE; exit 0'
stub_case "missing GIT_INDEX_FILE" 'echo GIT_DIR; echo GIT_WORK_TREE; exit 0'
stub_case "a failed git" 'echo GIT_DIR; echo GIT_INDEX_FILE; exit 1'

# py-syntax expands the same GIT_ENV_SCRUB, so one stub case proves it is
# wired there too: the gate must stop before listing any file.
stub_case_py() {
  printf '#!/bin/sh\nif [ "$1 $2" = "rev-parse --local-env-vars" ]; then exit 0; fi\nexec "%s" "$@"\n' \
    "$real_git" > "$stub/git"
  chmod u+x "$stub/git"
  git init -q "$work/pyrepo"
  printf 'x = 1\n' > "$work/pyrepo/ok.py"
  rc="$(PATH="$stub:$PATH" make_in "$work/pyrepo" -f "$mk" py-syntax)"
  [ "$rc" != 0 ] && ok || fail "py-syntax must fail closed when git's env var list is empty: $(last)"
  case "$(last)" in
    *"ERROR: 'git rev-parse --local-env-vars'"*) ok ;;
    *) fail "py-syntax must say the env var list is unusable: $(last)" ;;
  esac
}
stub_case_py

# --- the static check: green on the real Makefile, red on each mutated copy.
# A copy is written with sed into $work, never over the real file.
rc="$(make_in "$work" -f "$mk" test-env-scrub)"
[ "$rc" = 0 ] && ok || fail "test-env-scrub must pass on the real Makefile: $(last)"
[ -n "$(awk '/^local-ci:/' "$mk" | grep -w test-env-scrub)" ] && ok \
  || fail "test-env-scrub must be a local-ci prerequisite, or no gate ever runs it"
# mutant NAME CMD... - the Makefile filtered through CMD (stdin to stdout)
# must fail the check. Portable sed/awk only: BSD sed has no `\t`. Every
# edit is confined to the `test` recipe: the check's own patterns quote the
# same text, and a mutant that also rewrote them would pass vacuously.
mutant() {
  local name="$1" m="$work/Makefile.$1"
  shift
  "$@" < "$mk" > "$m"
  cmp -s "$mk" "$m" && fail "test bug: mutant '$name' did not change the Makefile"
  rc="$(make_in "$work" -f "$m" test-env-scrub)"
  [ "$rc" != 0 ] && ok || fail "test-env-scrub must fail on mutant '$name': $(last)"
  case "$(last)" in
    *"ERROR: test-env-scrub:"*) ok ;;
    *) fail "test-env-scrub must say why mutant '$name' fails: $(last)" ;;
  esac
}
# DEF confines an edit to the GIT_ENV_SCRUB definition.
DEF='/^GIT_ENV_SCRUB =/,/;$/'
# shellcheck disable=SC2016  # the $$ are Makefile text, matched literally
mutant no-unset sed "$DEF"'s/unset \$\$lev/: \$\$lev/'
# shellcheck disable=SC2016
mutant unset-not-a-command sed "$DEF"'s/^\([[:space:]]*\)unset \$\$lev/\1: unset $$lev/'
mutant no-lev sed "$DEF"'s/git rev-parse --local-env-vars)"/git version)"/'
mutant no-gitdir-guard sed "$DEF"'s/grep -qx GIT_DIR &&/true \&\&/'
mutant no-index-guard sed "$DEF"'s/grep -qx GIT_INDEX_FILE;/true;/'
mutant no-def sed 's/^GIT_ENV_SCRUB =/GIT_ENV_SCRUBBED =/'
mutant no-recipe sed 's/^test:/tests-renamed:/'
mutant no-py-recipe sed 's/^py-syntax:/py-syntax-renamed:/'
# shellcheck disable=SC2016
mutant test-unscrubbed sed '/^test:/,/^$/s/^\([[:space:]]*\)\$(GIT_ENV_SCRUB) \\$/\1: \\/'
# shellcheck disable=SC2016
mutant py-unscrubbed sed '/^py-syntax:/,/^$/s/^\([[:space:]]*\)@\$(GIT_ENV_SCRUB) \\$/\1@: \\/'
# The scrub moved behind the first git call / suite loop: a line inserted
# ahead of it in each recipe.
# shellcheck disable=SC2016
mutant test-after-loop awk '/^test:/ { t = 1 } t && /GIT_ENV_SCRUB\)/ && !d { print "\t  for t in $(TEST_FILES); do bash \"$$t\"; done; \\"; d = 1 } { print }'
# shellcheck disable=SC2016
mutant py-after-git awk '/^py-syntax:/ { t = 1 } t && /GIT_ENV_SCRUB\)/ && !d { print "\t@git status; \\"; d = 1 } { print }'

echo "PASS: make_test_env_scrub_test ($pass assertions)"
