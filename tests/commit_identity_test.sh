#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Tests for the commit-identity guard: .githooks/pre-commit and
# .githooks/pre-push, the rule in .githooks/commit_identity.py, and the
# `make commit-identity` gate. The rule: a user.email or user.name at git
# config scope `local` or `worktree` is refused; `-c` per command, the
# GIT_AUTHOR_*/GIT_COMMITTER_* variables and the global scope are allowed.
#
# Every case runs in scratch repositories under a scratch HOME, with
# GIT_CONFIG_GLOBAL pointing at a scratch file and GIT_CONFIG_NOSYSTEM set, so
# neither this machine's identity nor a system hooks dispatcher leaks in. A
# stand-in dispatcher holding the same contract as the sandbox's
# (/etc/git/hooks: exec <toplevel>/.githooks/<hook> with git's args and stdin)
# is wired through the scratch global core.hooksPath. The real dispatcher gets
# one case of its own when this machine has it, and a SKIP line when not.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mk="$repo_root/Makefile"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ok: $1"; }

# --- Wiring ------------------------------------------------------------------
recipe="$(awk '/^commit-identity:/{p=1; next} /^[^\t]/{p=0} p' "$mk")"
[ -n "$recipe" ] || fail "Makefile has no 'commit-identity' recipe"
grep -qF 'python3 -I .githooks/commit_identity.py check' <<<"$recipe" \
  || fail "the 'commit-identity' recipe must run 'python3 -I .githooks/commit_identity.py check'"
grep -qF '$(GIT_ENV_SCRUB)' <<<"$recipe" \
  || fail "the 'commit-identity' recipe must unset git's local env vars first (\$(GIT_ENV_SCRUB))"
grep -q 'STRICT' <<<"$recipe" && grep -q 'exit 1' <<<"$recipe" \
  || fail "the 'commit-identity' recipe must fail closed under STRICT=1 when python3 is absent"
grep -qw commit-identity <<<"$(grep -E '^local-ci:' "$mk")" \
  || fail "commit-identity must be a local-ci prerequisite (it is a blocking gate)"
ok "the 'commit-identity' target runs the check, scrubs git's env, honours STRICT and gates local-ci"
for h in pre-commit pre-push; do
  [ -x "$repo_root/.githooks/$h" ] || fail ".githooks/$h must be executable, or a dispatcher skips it"
done
ok ".githooks/pre-commit and .githooks/pre-push are executable"

if ! command -v python3 >/dev/null 2>&1; then
  [ -z "${STRICT:-}" ] || fail "python3 not installed and STRICT=1 - failing closed"
  echo "  SKIP: python3 not installed - the behaviour cases need it (set STRICT=1 to fail)"
  echo "commit_identity_test: $pass passed (behaviour cases skipped)"
  exit 0
fi

# --- Hermetic environment ----------------------------------------------------
work="$(mktemp -d "${TMPDIR:-/tmp}/commit-identity-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
work="$(cd "$work" && pwd -P)"
mkdir -p "$work/home" "$work/dispatch"
export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config"
export GIT_CONFIG_GLOBAL="$work/gitconfig" GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL \
  GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT EMAIL || true

# global_config [noidentity] - the scratch global config: hooks through the
# stand-in dispatcher, no signing, and a global identity unless told otherwise.
global_config() {
  {
    printf '[init]\n\tdefaultBranch = main\n'
    printf '[commit]\n\tgpgSign = false\n[tag]\n\tgpgSign = false\n'
    printf '[core]\n\thooksPath = %s\n' "$work/dispatch"
    [ "${1:-}" = noidentity ] || printf '[user]\n\tname = G\n\temail = g@x\n'
  } > "$GIT_CONFIG_GLOBAL"
}
global_config

# The stand-in dispatcher: the sandbox contract, minus its classic-hook arm.
cat > "$work/dispatch/pre-commit" <<'EOF'
#!/bin/sh
hook=$(basename "$0")
top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
if [ -x "$top/.githooks/$hook" ]; then exec "$top/.githooks/$hook" "$@"; fi
exit 0
EOF
cat "$work/dispatch/pre-commit" > "$work/dispatch/pre-push"
chmod u+x "$work/dispatch/pre-commit" "$work/dispatch/pre-push"

# new_repo DIR - a repository carrying this checkout's .githooks/, one commit.
new_repo() {
  git init -q "$1"
  mkdir -p "$1/.githooks"
  for f in pre-commit pre-push commit_identity.py; do
    cat "$repo_root/.githooks/$f" > "$1/.githooks/$f"
  done
  chmod u+x "$1/.githooks/pre-commit" "$1/.githooks/pre-push"
  git -C "$1" add .githooks
  git -C "$1" commit -q -m base || fail "fixture: the base commit in $1 was refused"
}

# try_commit DIR [git -c ...] - an empty commit; its stderr lands in $work/err.
try_commit() {
  local d="$1"; shift
  git -C "$d" "$@" commit -q --allow-empty -m m 2>"$work/err"
}
err() { cat "$work/err"; }

# --- Commit: the refusals ----------------------------------------------------
r="$work/r1"; new_repo "$r"
git -C "$r" config user.email a@b
head0="$(git -C "$r" rev-parse HEAD)"
if try_commit "$r"; then fail "a repository-scoped user.email must refuse the commit"; fi
[ "$(git -C "$r" rev-parse HEAD)" = "$head0" ] || fail "a refused commit must not move HEAD"
grep -q 'user.email' "$work/err" || fail "the refusal must name user.email: $(err)"
ok "a repository-scoped user.email is refused at commit"

r="$work/r2"; new_repo "$r"
git -C "$r" config user.name A
if try_commit "$r"; then fail "a repository-scoped user.name must refuse the commit"; fi
grep -q 'user.name' "$work/err" || fail "the refusal must name user.name: $(err)"
ok "a repository-scoped user.name is refused at commit"

r="$work/r3"; new_repo "$r"
git -C "$r" config extensions.worktreeConfig true
git -C "$r" config --worktree user.email w@x
[ -z "$(git -C "$r" config --local --get-all user.email || true)" ] \
  || fail "fixture: the worktree-scoped email leaked into the local scope"
if try_commit "$r"; then fail "a worktree-scoped user.email must refuse the commit"; fi
grep -q 'scope worktree' "$work/err" && grep -qF "$r/.git/config.worktree" "$work/err" \
  || fail "the refusal must name scope worktree and config.worktree: $(err)"
ok "a worktree-scoped user.email is refused"

# The incident: `git config user.email` inside a LINKED worktree writes the
# shared .git/config, so every worktree of the repository inherits it.
r="$work/r4"; new_repo "$r"
git -C "$r" worktree add -q -b side "$work/r4-linked"
git -C "$work/r4-linked" config user.email a@b
scope="$(git -C "$r" config --show-scope --show-origin --get user.email)"
[ "$scope" = "local	file:.git/config	a@b" ] \
  || fail "fixture: the linked worktree's write should land in the shared config, got: $scope"
if try_commit "$work/r4-linked"; then fail "the incident: a commit in the linked worktree must be refused"; fi
grep -qF "$r/.git/config" "$work/err" || fail "the refusal must name the shared config file: $(err)"
if try_commit "$r"; then fail "the incident: a commit in the main worktree must be refused too"; fi
ok "a user.email set in a linked worktree lands in the shared config and is refused"

# --- Commit: what stays allowed ----------------------------------------------
# No identity anywhere in config, so the commit can only take the one given.
r="$work/r5"; new_repo "$r"
global_config noidentity
try_commit "$r" -c user.email=c@x -c user.name=C || fail "-c per command must be allowed: $(err)"
[ "$(git -C "$r" log -1 --format=%ae)" = c@x ] || fail "fixture: the -c identity was not used"
ok "-c user.email per command is allowed"

GIT_AUTHOR_NAME=E GIT_AUTHOR_EMAIL=e@x GIT_COMMITTER_NAME=E GIT_COMMITTER_EMAIL=e@x \
  try_commit "$r" || fail "GIT_AUTHOR_*/GIT_COMMITTER_* must be allowed: $(err)"
[ "$(git -C "$r" log -1 --format=%ae/%ce)" = e@x/e@x ] || fail "fixture: the env identity was not used"
ok "GIT_AUTHOR_EMAIL/GIT_COMMITTER_EMAIL are allowed"
global_config

r="$work/r6"; new_repo "$r"
try_commit "$r" || fail "a global identity must be allowed: $(err)"
ok "a global identity is allowed"

# --- Push --------------------------------------------------------------------
remote="$work/remote.git"; git init -q --bare "$remote"
r="$work/r7"; new_repo "$r"
git -C "$r" remote add origin "$remote"
git -C "$r" push -q origin main 2>"$work/err" || fail "a clean push must pass: $(err)"
# A rebase replays commits without pre-commit, so only pre-push sees them.
# The topic commit changes a file: a rebase can drop an empty one.
git -C "$r" checkout -q -b topic
printf 'topic\n' > "$r/topic.txt"; git -C "$r" add topic.txt
try_commit "$r" || fail "fixture: topic commit refused: $(err)"
git -C "$r" checkout -q main
try_commit "$r" || fail "fixture: main commit refused: $(err)"
git -C "$r" checkout -q topic
git -C "$r" config user.email a@b
git -C "$r" rebase -q main 2>"$work/err" || fail "fixture: the rebase failed: $(err)"
[ "$(git -C "$r" log -1 --format=%ce)" = a@b ] \
  || fail "fixture: the rebase did not commit under the repository-scoped identity"
if git -C "$r" push -q origin topic 2>"$work/err"; then
  fail "pre-push must refuse after a rebase under a repository-scoped identity"
fi
grep -q 'pre-push: refusing: user.email' "$work/err" || fail "the pre-push refusal must name the key: $(err)"
if git -C "$remote" rev-parse -q --verify refs/heads/topic >/dev/null; then
  fail "a refused push must not create the remote branch"
fi
ok "pre-push refuses after a rebase under a repository-scoped identity"
git -C "$r" config --unset user.email

# Every push shape git can hand pre-push on stdin, with a clean config.
git -C "$r" push -q origin topic 2>"$work/err" || fail "pre-push: a new branch must pass: $(err)"
git -C "$r" push -q origin :topic 2>"$work/err" || fail "pre-push: a deletion must pass: $(err)"
git -C "$r" tag -a -m t v1 2>"$work/err" || fail "fixture: tag: $(err)"
git -C "$r" push -q origin v1 2>"$work/err" || fail "pre-push: a tag push must pass: $(err)"
other="$work/other"; git clone -q "$remote" "$other"
try_commit "$other" || fail "fixture: other commit refused: $(err)"
git -C "$other" push -q origin main 2>"$work/err" || fail "fixture: other push: $(err)"
# r has never fetched other's commit, so the remote oid on stdin is unknown here.
git -C "$r" push -q --force origin main 2>"$work/err" \
  || fail "pre-push: a missing remote oid must pass: $(err)"
git -C "$r" remote add fork "$work/fork.git"; git init -q --bare "$work/fork.git"
git -C "$r" push -q fork main 2>"$work/err" || fail "pre-push: a second remote must pass: $(err)"
ok "pre-push tolerates a new branch, a deletion, a tag push and a missing remote oid"

# --- The message ---------------------------------------------------------------
r="$work/r 8"; new_repo "$r"
git -C "$r" config user.email a@b
if try_commit "$r"; then fail "fixture: the commit in '$r' should be refused"; fi
want="commit-identity: pre-commit: refusing: user.email 'a@b' is set at scope local in $r/.git/config; fix: git config --file '$r/.git/config' --unset-all user.email"
grep -qxF "$want" "$work/err" || fail "the refusal line is not what was expected: $(err)"
grep -qF "git -c user.email=" "$work/err" || fail "the refusal must point at 'git -c user.email=...': $(err)"
[ "$(wc -l < "$work/err")" -eq 2 ] || fail "one line per offending key plus one pointer, got: $(err)"
ok "the message names the file and the --unset fix, escaped"

r="$work/r9"; new_repo "$r"
git -C "$r" config user.name "$(printf 'x\033[31my\nforged\342\200\256z\\')"
if try_commit "$r"; then fail "fixture: the commit in $r should be refused"; fi
grep -qF "'x\\x1b[31my\\x0aforged\\u202ez\\\\'" "$work/err" \
  || fail "control characters must print escaped: $(err)"
if LC_ALL=C grep -q "$(printf '\033')" "$work/err"; then fail "a raw ESC reached the message"; fi
[ "$(wc -l < "$work/err")" -eq 2 ] || fail "an LF in a value must not forge a line: $(err)"
ok "control characters in a value are escaped"

# --- The dispatcher contract from a linked worktree ---------------------------
r="$work/r10"; new_repo "$r"
git -C "$r" worktree add -q -b side "$work/r10-linked"
git -C "$r" config user.email a@b
# Direct invocation, the way a dispatcher execs it: pre-push gets git's two
# args and a ref line on stdin, run from the linked worktree's toplevel.
line="refs/heads/side $(git -C "$r" rev-parse HEAD) refs/heads/side 0000000000000000000000000000000000000000"
set +e
(cd "$work/r10-linked" && printf '%s\n' "$line" | .githooks/pre-push origin "$work/remote.git") 2>"$work/err"
rc=$?
set -e
[ "$rc" -eq 1 ] && grep -qF "$r/.git/config" "$work/err" \
  || fail "pre-push run with git's args and stdin from a linked worktree must exit 1, got $rc: $(err)"
git -C "$r" config --unset user.email
(cd "$work/r10-linked" && printf '%s\n' "$line" | .githooks/pre-push origin "$work/remote.git") 2>"$work/err" \
  || fail "pre-push with git's args and stdin must pass on a clean config: $(err)"
(cd "$work/r10-linked" && .githooks/pre-commit </dev/null) 2>"$work/err" \
  || fail "pre-commit with no stdin must pass on a clean config: $(err)"
ok "the hook runs through the dispatcher contract (args and stdin) from a linked worktree"

# The sandbox's real dispatcher, when this machine has one.
if [ -x /etc/git/hooks/pre-commit ]; then
  git -C "$r" config user.email a@b
  if (unset GIT_CONFIG_NOSYSTEM
      git -C "$work/r10-linked" -c core.hooksPath=/etc/git/hooks commit -q --allow-empty -m m) 2>"$work/err"; then
    fail "the real dispatcher at /etc/git/hooks must run .githooks/pre-commit and refuse"
  fi
  grep -q 'commit-identity: pre-commit: refusing' "$work/err" \
    || fail "the refusal through /etc/git/hooks must come from this guard: $(err)"
  git -C "$r" config --unset user.email
  ok "the real dispatcher at /etc/git/hooks runs the guard from a linked worktree"
else
  echo "  SKIP: no dispatcher at /etc/git/hooks on this machine - the stand-in covered the contract"
fi

# --- The make gate -------------------------------------------------------------
r="$work/r11"; new_repo "$r"
make -s -C "$r" -f "$mk" commit-identity >"$work/out" 2>&1 \
  || fail "make commit-identity must pass without a repository identity: $(cat "$work/out")"
git -C "$r" config user.email a@b
if make -s -C "$r" -f "$mk" commit-identity >"$work/out" 2>&1; then
  fail "make commit-identity must fail on a repository with a local identity"
fi
grep -q 'commit-identity: check: refusing: user.email' "$work/out" \
  || fail "make commit-identity must say why it failed: $(cat "$work/out")"
ok "make commit-identity fails on a repository with a local identity and passes without"

# docs/development.md quotes the refusal line; hold it to the real output.
doc_line="$(grep -E "^commit-identity: check: refusing: " "$repo_root/docs/development.md")" \
  || fail "docs/development.md no longer quotes the refusal line"
grep -qxF "${doc_line//\/path/$r}" "$work/out" \
  || fail "the refusal line docs/development.md quotes drifted from the output: $(cat "$work/out")"
ok "the refusal line docs/development.md quotes matches the output"

echo "commit_identity_test: $pass passed"
