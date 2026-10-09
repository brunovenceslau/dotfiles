#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Tests for `install.sh identity`, its --rotate, the identity step of `install`
# and the stale-key report of _signing_advisory (lib/host_identity.py, called
# through install.sh's do_identity).
# Hermetic: a mktemp HOME and XDG_CONFIG_HOME, GIT_CONFIG_SYSTEM=/dev/null,
# fixture allowed-signers files, and a fake `ssh-add` first on PATH that prints
# fixture public keys (or fails the way the real one does). The fake-agent
# cases use throwaway PUBLIC keys only. The last case is end to end: a real
# throwaway ssh-agent on a short socket path holds freshly generated keys, and
# a real `git commit -S` signs with the config the step wrote.
# Not on the repo's shellcheck surface.
set -euo pipefail

# A privilege skip: install.sh refuses root for every subcommand.
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  echo "SKIP: host_identity_test (running as root: install.sh refuses root)"
  exit 0
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
installer="$repo_root/install.sh"
module="$repo_root/lib/host_identity.py"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); }
for t in git python3 ssh-keygen ssh-agent ssh-add; do
  if ! command -v "$t" >/dev/null 2>&1; then
    if [ -n "${STRICT:-}" ]; then fail "$t not installed and STRICT=1"; fi
    echo "SKIP: host_identity_test ($t unavailable)"; exit 0
  fi
done
real_ssh_add="$(command -v ssh-add)"

# No trailing slash: macOS's TMPDIR ends in one, and a "T//" in $work would
# not match the origins git prints, which may spell the path with one slash.
tmp="${TMPDIR:-/tmp}"
work="$(mktemp -d "${tmp%/}/host_identity_test.XXXXXX")"
# Every run of the step makes an empty directory for git under TMPDIR: pinned
# here so a case that leaves one behind fails the suite (checked at the end)
# instead of littering the caller's /tmp. Cases that test TMPDIR set their own.
export TMPDIR="$work/tmp"
mkdir "$TMPDIR"
agent_pid="" decoy_pid=""
cleanup() {
  if [ -n "$agent_pid" ]; then kill "$agent_pid" 2>/dev/null || :; fi
  if [ -n "$decoy_pid" ]; then kill "$decoy_pid" 2>/dev/null || :; fi
  rm -rf "$work"
  if [ -n "${sockdir:-}" ]; then rm -rf "$sockdir"; fi
  if [ -n "${stubdir:-}" ]; then rm -rf "$stubdir"; fi
}
trap cleanup EXIT INT TERM
# Every case that could hang on a FIFO runs through this, with a time bound.
# shellcheck source=tests/lib/bounded_run.sh
. "$repo_root/tests/lib/bounded_run.sh"

# start_scratch_agent DIR - start a throwaway ssh-agent on DIR/a and export
# its SSH_AUTH_SOCK and SSH_AGENT_PID, or fail. Never an inherited agent: the
# two variables are unset first, so a failed start cannot leave ssh-add, or
# the cleanup's kill, aimed at the caller's (possibly forwarded) agent. `eval`
# of an empty substitution succeeds, so the start is judged by its result:
# the socket must be exactly DIR/a. Its PID is recorded as soon as that holds
# (it is then ours), so cleanup stops the agent even if a later check fails.
start_scratch_agent() {
  local agent_env
  unset SSH_AUTH_SOCK SSH_AGENT_PID
  agent_env="$(ssh-agent -s -a "$1/a")" || fail "e2e: ssh-agent did not start"
  eval "$agent_env" >/dev/null
  [ "${SSH_AUTH_SOCK:-}" = "$1/a" ] \
    || fail "e2e: the scratch ssh-agent is not on $1/a (SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-unset})"
  agent_pid="${SSH_AGENT_PID:-}"
  [ -S "$1/a" ] && [ -n "$agent_pid" ] || fail "e2e: the scratch ssh-agent on $1/a did not come up"
}

K1='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE7ZriufNPIzaGKLCOFNHpr6/MYnrT97GT7G1THBmdJR'
K2='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMVL61RItf9Zrt0cJfybtAiQI7oSyIe8GXLQebcE3X7J'
K3='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPDo+8AMotufAJ/0CU6i0MEopuTAOsdMvI3VZ77+pErG'
# fp KEY - its SHA256 fingerprint, from ssh-keygen itself (the reference).
fp() { printf '%s x\n' "$1" > "$work/fp.pub"; ssh-keygen -lf "$work/fp.pub" | awk '{ print $2 }'; }
FP1="$(fp "$K1")"; FP2="$(fp "$K2")"; FP3="$(fp "$K3")"

# The fake ssh-add: prints $FAKE_AGENT_KEYS (one key per line) for -L, exits
# 1 with the real message when it is empty, and 2 when FAKE_AGENT_DOWN is set.
mkdir -p "$work/fakebin"
cat > "$work/fakebin/ssh-add" <<'EOF'
#!/bin/sh
[ "$1" = "-L" ] || exit 64
if [ -n "${FAKE_AGENT_DOWN:-}" ]; then
  echo "Could not open a connection to your authentication agent." >&2; exit 2
fi
if [ -z "${FAKE_AGENT_KEYS:-}" ]; then echo "The agent has no identities."; exit 1; fi
printf '%s\n' "$FAKE_AGENT_KEYS"
EOF
chmod u+x "$work/fakebin/ssh-add"

export GIT_CONFIG_SYSTEM=/dev/null
# No agent of the caller's is ever reachable from this suite (see the e2e case).
unset GIT_CONFIG_GLOBAL GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT CANGA_HOST_ALLOWED_SIGNERS SSH_AUTH_SOCK SSH_AGENT_PID SSH_CONNECTION
unset FAKE_AGENT_DOWN
export PATH="$work/fakebin:$PATH"

# fresh - a new, empty HOME with the default allowed-signers path, and a
# ~/.config/git/config shaped like the one the link engine writes
# (_write_git_local_config in lib/link.sh): an include of the tracked config
# by absolute path, then of config.local, so effective reads see what a real
# host sees, the tracked gpg.format = ssh and commit.gpgsign = true included.
# The tracked config is read from a copy of its bytes under $work: its own
# relative include then reaches no repo-side config.local, which a checkout
# on a legacy host may still hold.
mkdir -p "$work/tracked/config/git"
tracked_cfg="$work/tracked/config/git/config"
cat "$repo_root/config/git/config" > "$tracked_cfg"
n=0
fresh() {
  n=$((n + 1))
  export HOME="$work/h$n" XDG_CONFIG_HOME="$work/h$n/.config"
  mkdir -p "$XDG_CONFIG_HOME/git"
  printf '[include]\n\tpath = %s\n[include]\n\tpath = config.local\n' "$tracked_cfg" > "$XDG_CONFIG_HOME/git/config"
  signers="$XDG_CONFIG_HOME/git/allowed_signers"
  local_cfg="$XDG_CONFIG_HOME/git/config.local"
  : > "$signers"
}
get() { git config --file "$local_cfg" --get "$1" || echo UNSET; }
# named - give config.local a user.name, which the step never writes: the
# automatic step is quiet only on a host that has one (the tracked
# user.useConfigOnly = true makes git refuse every commit without it).
named() { git config --file "$local_cfg" user.name "Jane Doe"; }
# run ARGS... - install.sh identity, capturing combined output and status.
run() { rc=0; out="$("$installer" identity "$@" 2>&1)" || rc=$?; }
expect_rc() { [ "$rc" -eq "$1" ] || fail "$2: exit $rc, want $1 (output: $out)"; }
has() { grep -qF -- "$1" <<<"$out" || fail "$2: output lacks [$1] (output: $out)"; }
lacks() { ! grep -qF -- "$1" <<<"$out" || fail "$2: output has [$1] (output: $out)"; }
unwritten() { [ ! -e "$local_cfg" ] || fail "$1 wrote config.local: $(cat "$local_cfg")"; }

# --- conformance: the matcher agrees with `ssh-keygen -Y verify` ------------
# Once per time zone: a local validity time is read in the zone the process
# runs in, so UTC alone hides a zone-dependent verdict and a DST error. One
# zone east of UTC, one west, one with DST (Europe/Berlin; Los Angeles has it
# too). CI runs in UTC, which is why the zones are set here, not inherited.
ssh-keygen -q -t ed25519 -N '' -C conformance -f "$work/conf_key"
printf 'conformance message\n' > "$work/conf_msg"
ssh-keygen -q -Y sign -n git -f "$work/conf_key" "$work/conf_msg" 2>/dev/null
for zone in UTC Asia/Tokyo America/Los_Angeles Europe/Berlin; do
  # A zone this host has no data for silently reads as UTC, and the pass
  # would prove nothing about it. None of the three is ever at +0000. Asked of
  # python3 itself, the process under test: a `date` may carry its own zone
  # data and answer correctly where python3 cannot.
  if [ "$zone" != UTC ] && [ "$(TZ="$zone" python3 -I -c 'import time; print(time.strftime("%z"))')" = "+0000" ]; then
    fail "conformance: TZ=$zone reads as UTC here (is tzdata installed?)"
  fi
  out="$(TZ="$zone" python3 -I -B "$repo_root/tests/host_identity_conformance.py" "$module" \
    "$repo_root/tests/fixtures/allowed_signers/verify-git.txt" "$work/conf_key.pub" \
    "$work/conf_msg.sig" "$work/conf_msg" 2>&1)" || fail "conformance in TZ=$zone: $out"
  has "oracle checked, revocation and times checked" "conformance ran against ssh-keygen in TZ=$zone"
done
# The generated differential leg: once, since its lines carry no local time
# that a zone could move (a seconds field of 61 is refused in every zone).
out="$(python3 -I -B "$repo_root/tests/host_identity_conformance.py" --differential "$module" \
  "$work/conf_key.pub" "$work/conf_msg.sig" "$work/conf_msg" 2>&1)" || fail "differential leg: $out"
has " 0 failure(s)" "the differential leg ran to the end"
ok

# --- the scrubbed git environment still covers git's own local list ---------
missing="$(python3 -I -B -c '
import importlib.util, subprocess, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
names = subprocess.run(["git", "rev-parse", "--local-env-vars"], stdout=subprocess.PIPE, universal_newlines=True, check=True).stdout.split()
print(" ".join(x for x in names if x not in m.GIT_LOCAL_ENV))
' "$module")"
[ -z "$missing" ] || fail "GIT_LOCAL_ENV misses git's local env vars: $missing"
ok

# --- unit checks: Python 3.9 floor, env scrub, key types, fallbacks ----------
# SCRATCH is passed through a symlink on purpose: macOS's TMPDIR already is one
# (/var -> /private/var), so a check that compares a path with getcwd() fails
# only there unless Linux runs it behind a link too.
mkdir -p "$work/units-real"
ln -s units-real "$work/units"
out="$(python3 -I -B "$repo_root/tests/host_identity_units.py" "$module" "$work/units" 2>&1)" \
  || fail "unit checks: $out"
has "0 failure(s)" "unit checks ran to the end"
ok

# --- happy path: one principal, one key, comment mismatch ignored -----------
fresh
printf '# comment line\n\nme@example.com %s host-a-comment\nother@example.com %s\n' "$K1" "$K2" > "$signers"
export FAKE_AGENT_KEYS="$K1 a-totally-different-agent-comment"
run
expect_rc 0 "happy path"
[ "$(get user.email)" = "me@example.com" ] || fail "happy path: user.email is $(get user.email)"
[ "$(get user.signingkey)" = "key::$K1" ] || fail "happy path: user.signingkey is $(get user.signingkey)"
[ "$(get commit.gpgsign)" = UNSET ] || fail "happy path: commit.gpgsign written beside the tracked true"
[ "$(get tag.gpgsign)" = "true" ] || fail "happy path: tag.gpgsign"
[ "$(get gpg.ssh.allowedSignersFile)" = "$signers" ] || fail "happy path: allowedSignersFile is $(get gpg.ssh.allowedSignersFile)"
[ "$(get user.name)" = "UNSET" ] || fail "happy path: user.name written without --name"
has "user.name is not set" "happy path hints at --name"
[ ! -e "$local_cfg.bak" ] || fail "happy path: a .bak for a config.local that did not exist"
ok

# --- idempotent second run: no rewrite, no .bak ------------------------------
before="$(ls -li "$local_cfg")"
run
expect_rc 0 "second run"
has "already configured for me@example.com ($FP1)" "second run reports no-op with the fingerprint"
[ "$(ls -li "$local_cfg")" = "$before" ] || fail "second run rewrote config.local"
[ ! -e "$local_cfg.bak" ] || fail "second run created a .bak"
ok

# --- --name, and a .bak created exactly once for an existing file -----------
run --name "Jane Doe"
expect_rc 0 "--name"
[ "$(get user.name)" = "Jane Doe" ] || fail "--name: user.name is $(get user.name)"
[ -f "$local_cfg.bak" ] || fail "--name: no .bak before modifying an existing config.local"
grep -q 'me@example.com' "$local_cfg.bak" && ! grep -q 'Jane' "$local_cfg.bak" \
  || fail "--name: the .bak is not the pre-modification content"
bak_before="$(cat "$local_cfg.bak")"
git config --file "$local_cfg" --unset tag.gpgsign
run
expect_rc 0 "re-add tag.gpgsign"
[ "$(get tag.gpgsign)" = "true" ] || fail "re-add tag.gpgsign"
[ "$(cat "$local_cfg.bak")" = "$bak_before" ] || fail "the pristine .bak was overwritten"
[ -z "$(find "$XDG_CONFIG_HOME/git" -name 'config.local.bak?*' -o -name '.config.local.*')" ] \
  || fail "stray backup or temp files left behind"
ok

# --- usage errors: exit 2, nothing written -----------------------------------
fresh
for argv in "--bogus" "--name" "--name a --name b" "--rotate --rotate" "--rotate --name x"; do
  # shellcheck disable=SC2086  # word-split on purpose
  run $argv
  expect_rc 2 "usage: $argv"
done
run --name ""; expect_rc 2 "usage: empty --name"
run --name "Evil <x@y>"; expect_rc 2 "usage: --name with <>"
run --name "$(printf 'a\nb')"; expect_rc 2 "usage: --name with a newline"
unwritten "a usage error"
ok

# --- namespaces filter, quoted option with spaces and commas -----------------
fresh
printf 'me@example.com namespaces="file" %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
run
expect_rc 1 "namespaces=file only"
has "no ssh-agent key is listed for the git namespace" "namespaces=file only"
unwritten "namespaces=file"
printf 'me@example.com namespaces="file,git",valid-after="20000101" %s\n' "$K1" > "$signers"
run
expect_rc 0 "namespaces list containing git"
[ "$(get user.email)" = "me@example.com" ] || fail "namespaces list containing git"
fresh
printf 'me@example.com valid-before="20991231235959Z",namespaces="g*,x y" %s c\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
run
expect_rc 0 "quoted option values with spaces and commas"
[ "$(get user.email)" = "me@example.com" ] || fail "quoted options: user.email"
ok

# --- expired valid-before, negated namespace, cert-authority, pattern -------
fresh
export FAKE_AGENT_KEYS="$K1"
for line in \
  "me@example.com valid-before=\"20000101\" $K1" \
  "me@example.com namespaces=\"*,!git\" $K1" \
  "me@example.com cert-authority $K1" \
  "*@example.com $K1" \
  "me@example.com bogus-option $K1" \
  "<me@example.com> $K1" \
  "me@example.com $K1"x; do
  printf '%s\n' "$line" > "$signers"
  run
  expect_rc 1 "unusable entry [$line]"
  unwritten "unusable entry [$line]"
done
ok

# --- no match, no agent, agent down, no file ---------------------------------
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K2"
run; expect_rc 1 "no match"; has "writing nothing" "no match"
FAKE_AGENT_KEYS="" run; expect_rc 1 "empty agent"; has "the ssh-agent holds no keys" "empty agent"
FAKE_AGENT_DOWN=1 run; expect_rc 1 "agent down"; has "cannot reach an ssh-agent" "agent down"
rm -f "$signers"
run; expect_rc 1 "no file"; has "no allowed-signers file found" "no file"
unwritten "a failed run"
ok

# --- the lookup order: env var, then gpg.ssh.allowedSignersFile, then XDG ----
fresh
export FAKE_AGENT_KEYS="$K1"
printf 'cfg@example.com %s\n' "$K1" > "$HOME/cfg_signers"
printf 'env@example.com %s\n' "$K1" > "$HOME/env_signers"
printf 'default@example.com %s\n' "$K1" > "$signers"
git config --file "$XDG_CONFIG_HOME/git/config" gpg.ssh.allowedSignersFile '~/cfg_signers'
CANGA_HOST_ALLOWED_SIGNERS="$HOME/env_signers" run
expect_rc 0 "env var wins"
[ "$(get user.email)" = "env@example.com" ] || fail "env var wins: $(get user.email)"
has "differs from gpg.ssh.allowedSignersFile" "env vs config disagreement is reported"
[ "$(get gpg.ssh.allowedSignersFile)" = "UNSET" ] || fail "env var wins: allowedSignersFile written over a set one"
rm -f "$local_cfg"
run
expect_rc 0 "allowedSignersFile with ~ is used"
[ "$(get user.email)" = "cfg@example.com" ] || fail "allowedSignersFile: $(get user.email)"
rm -f "$local_cfg"
CANGA_HOST_ALLOWED_SIGNERS="$HOME/missing" run
expect_rc 1 "a set but missing source is reported, not skipped"
has "$HOME/missing" "missing source named"
# XDG_CONFIG_HOME away from ~/.config: the default file is looked up there.
fresh
export XDG_CONFIG_HOME="$HOME/xdg"
mkdir -p "$XDG_CONFIG_HOME/git"
mv "$HOME/.config/git/config" "$XDG_CONFIG_HOME/git/config"
signers="$XDG_CONFIG_HOME/git/allowed_signers"; local_cfg="$XDG_CONFIG_HOME/git/config.local"
printf 'xdg@example.com %s\n' "$K1" > "$signers"
run
expect_rc 0 "XDG_CONFIG_HOME honoured"
[ "$(get user.email)" = "xdg@example.com" ] || fail "XDG_CONFIG_HOME: $(get user.email)"
ok

# --- a repository's config and a caller's -c never steer the trust root ------
fresh
export FAKE_AGENT_KEYS="$K1"
printf 'me@example.com %s\n' "$K1" > "$signers"
printf 'evil@example.com %s\n' "$K1" > "$HOME/evil_signers"
git init -q "$HOME/repo"
git -C "$HOME/repo" config gpg.ssh.allowedSignersFile "$HOME/evil_signers"
git -C "$HOME/repo" config user.email evil@example.com
# $HOME itself a repository (some people version their home): its local
# config is not the user's global identity either.
git init -q "$HOME"
git -C "$HOME" config gpg.ssh.allowedSignersFile "$HOME/evil_signers"
rc=0
out="$(cd "$HOME/repo" && GIT_DIR="$HOME/repo/.git" GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=gpg.ssh.allowedSignersFile GIT_CONFIG_VALUE_0="$HOME/evil_signers" \
  GIT_CONFIG_PARAMETERS="'user.email'='evil@example.com'" "$installer" identity 2>&1)" || rc=$?
expect_rc 0 "ambient repository and -c config ignored"
[ "$(get user.email)" = "me@example.com" ] || fail "ambient config steered the identity: $(get user.email)"
ok
# A $TMPDIR inside a repository: git runs from an empty directory there, and
# GIT_CEILING_DIRECTORIES keeps it from climbing into that repository.
rm -f "$local_cfg"
mkdir -p "$HOME/repo/tmp"
rc=0
out="$(cd "$HOME/repo" && GIT_WORK_TREE="$HOME/repo" TMPDIR="$HOME/repo/tmp" "$installer" identity 2>&1)" || rc=$?
expect_rc 0 "a TMPDIR inside a repository"
[ "$(get user.email)" = "me@example.com" ] || fail "the repository around TMPDIR steered the identity: $(get user.email)"
[ -z "$(ls -A "$HOME/repo/tmp")" ] || fail "the empty git directory was left in TMPDIR: $(ls -A "$HOME/repo/tmp")"
ok

# A TMPDIR that is a symlink into that repository: the ceiling is taken from
# the working directory git itself sees, so the link changes nothing.
rm -f "$local_cfg"
ln -s "$HOME/repo/tmp" "$HOME/tmp-link"
rc=0
out="$(cd "$HOME/repo" && TMPDIR="$HOME/tmp-link" "$installer" identity 2>&1)" || rc=$?
expect_rc 0 "a TMPDIR that is a symlink into a repository"
[ "$(get user.email)" = "me@example.com" ] || fail "TMPDIR through a symlink: $(get user.email)"
ok

# A platform case: on a case-insensitive file system (macOS's default APFS)
# a TMPDIR spelled in other letters names the same directory, and git sees
# the spelling getcwd() gives, which the ceiling must be.
if [ "$(uname -s)" = Darwin ] && [ -d "$HOME/REPO/TMP" ]; then
  rm -f "$local_cfg"
  rc=0
  out="$(cd "$HOME/repo" && TMPDIR="$HOME/REPO/TMP" "$installer" identity 2>&1)" || rc=$?
  expect_rc 0 "a TMPDIR spelled in other letters, inside a repository"
  [ "$(get user.email)" = "me@example.com" ] || fail "TMPDIR in other letters: $(get user.email)"
  [ -z "$(ls -A "$HOME/repo/tmp")" ] || fail "TMPDIR in other letters: left $(ls -A "$HOME/repo/tmp")"
  ok
else
  echo "SKIP: a TMPDIR spelled in other letters (not macOS on a case-insensitive file system)"
fi

# An execute-only working directory: the step steps into its empty
# directory and back, and needs no read permission on where it started.
# Linux returns through an O_PATH descriptor. macOS has none: it returns by
# path, or refuses when it cannot tell that path; never anything else.
# The units in tests/host_identity_units.py are the only guard for the
# fchdir() return, the GIT_TRACE* scrub, the "cannot return" refusal and
# git()'s refusal against mutation.
rm -f "$local_cfg"
mkdir "$HOME/xonly"
chmod 0311 "$HOME/xonly"
rc=0
out="$(cd "$HOME/xonly" && "$installer" identity 2>&1)" || rc=$?
chmod 0700 "$HOME/xonly"
if [ "$(uname -s)" = Darwin ] && [ "$rc" -eq 1 ]; then
  has "identity: not reading the git config: cannot open the current directory to return to it (" \
    "an execute-only working directory on macOS"
  unwritten "an execute-only working directory on macOS"
else
  expect_rc 0 "an execute-only working directory"
  [ "$(get user.email)" = "me@example.com" ] || fail "an execute-only working directory: $(get user.email)"
fi
ok

# An inherited GIT_CEILING_DIRECTORIES is replaced, never kept: neither one
# that misses, nor one whose empty entry stops git resolving what follows.
for inherited in /nonexistent ":$HOME/repo/tmp"; do
  rm -f "$local_cfg"
  rc=0
  out="$(cd "$HOME/repo" && GIT_CEILING_DIRECTORIES="$inherited" TMPDIR="$HOME/repo/tmp" "$installer" identity 2>&1)" \
    || rc=$?
  expect_rc 0 "inherited GIT_CEILING_DIRECTORIES=$inherited"
  [ "$(get user.email)" = "me@example.com" ] || fail "GIT_CEILING_DIRECTORIES=$inherited: $(get user.email)"
done
[ -z "$(ls -A "$HOME/repo/tmp")" ] || fail "an empty git directory was left in TMPDIR: $(ls -A "$HOME/repo/tmp")"
ok

# --- git that cannot be kept out of a repository: said, in every mode -------
# A ':' in TMPDIR cannot be a GIT_CEILING_DIRECTORIES entry; a relative
# GIT_CONFIG_GLOBAL would name a file in the empty directory git runs from.
# Neither may read as an unset gpg.format or a missing include.
fresh
export FAKE_AGENT_KEYS="$K1"
printf 'me@example.com %s\n' "$K1" > "$signers"
mkdir -p "$work/co:lon"
for setting in "TMPDIR=$work/co:lon" "GIT_CONFIG_GLOBAL=.config/git/config"; do
  rc=0; out="$(cd "$HOME" && env "$setting" "$installer" identity 2>&1)" || rc=$?
  expect_rc 1 "$setting, identity"; has "identity: not reading the git config: " "$setting, identity"
  lacks "gpg.format is unset" "$setting, identity"; unwritten "$setting, identity"
  rc=0; out="$(cd "$HOME" && env "$setting" python3 -I -B "$module" --config-local "$local_cfg" \
    --installer "$installer" --mode auto 2>&1)" || rc=$?
  expect_rc 1 "$setting, auto"; has "identity: not reading the git config: " "$setting, auto"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] || fail "$setting, auto: more than one line: $out"
  unwritten "$setting, auto"
  rc=0; out="$(cd "$HOME" && env "$setting" python3 -I -B "$module" --config-local "$local_cfg" \
    --installer "$installer" --mode check 2>&1)" || rc=$?
  expect_rc 0 "$setting, check"; has "identity: not reading the git config: " "$setting, check"
  rc=0; out="$(cd "$HOME" && env "$setting" "$installer" doctor 2>&1)" || rc=$?
  expect_rc 1 "$setting, doctor"; has "doctor: git: not reading the git config: " "$setting, doctor"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] || fail "$setting, doctor: more than one line: $out"
  [ -z "$(ls -A "$work/co:lon")" ] || fail "$setting, doctor: left files in the refused TMPDIR: $(ls -A "$work/co:lon")"
done
has "GIT_CONFIG_GLOBAL=.config/git/config is not an absolute path" "a relative GIT_CONFIG_GLOBAL is named"
# A global config git cannot parse: git cannot start at all, and the step
# quotes git's own error rather than calling it a repository question.
fresh
export FAKE_AGENT_KEYS="$K1"
printf 'me@example.com %s\n' "$K1" > "$signers"
printf '[user\n' >> "$XDG_CONFIG_HOME/git/config"
rc=0; out="$(cd "$HOME" && "$installer" identity 2>&1)" || rc=$?
expect_rc 1 "an unparsable global config, identity"
has "identity: not reading the git config: git cannot start (" "an unparsable global config, identity"
has "bad config line" "an unparsable global config: git's error is quoted"
lacks "absence of a repository" "an unparsable global config, identity"; unwritten "an unparsable global config"
rc=0; out="$(cd "$HOME" && python3 -I -B "$module" --config-local "$local_cfg" --installer "$installer" \
  --mode check 2>&1)" || rc=$?
expect_rc 0 "an unparsable global config, check"; has "git cannot start (" "an unparsable global config, check"
[ -z "$(ls -A "$work/co:lon")" ] || fail "a refused run left a directory in TMPDIR: $(ls -A "$work/co:lon")"
ok

# --- includeIf gitdir: in the global config is read, and never applies -------
# git once died on these reads (rc 128, "Invalid path") when the step pointed
# GIT_DIR at a path that cannot exist, so the step wrote nothing and blamed a
# missing include. Each condition here would hold for a repository under
# ~/work, and the one on the empty directory's parent would hold if that
# directory were a repository; none may reach the trust root or the identity.
for cond in gitdir gitdir/i; do
  fresh
  export FAKE_AGENT_KEYS="$K1"
  printf 'me@example.com %s\n' "$K1" > "$signers"
  printf 'evil@example.com %s\n' "$K1" > "$HOME/evil_signers"
  printf '[user]\n\temail = evil@example.com\n[gpg "ssh"]\n\tallowedSignersFile = %s\n' "$HOME/evil_signers" \
    > "$XDG_CONFIG_HOME/git/evil.inc"
  mkdir -p "$HOME/tmp"
  printf '[includeIf "%s:~/work/"]\n\tpath = evil.inc\n[includeIf "%s:%s/tmp/**"]\n\tpath = evil.inc\n[includeIf "%s:**"]\n\tpath = evil.inc\n' \
    "$cond" "$cond" "$HOME" "$cond" >> "$XDG_CONFIG_HOME/git/config"
  git init -q "$HOME/work/r"
  [ "$(git -C "$HOME/work/r" config --get user.email)" = evil@example.com ] \
    || fail "$cond: the fixture's condition does not hold inside ~/work/r, so this case proves nothing"
  for where in "$HOME" "$HOME/work/r"; do
    rm -f "$local_cfg"
    rc=0
    out="$(cd "$where" && TMPDIR="$HOME/tmp" "$installer" identity 2>&1)" || rc=$?
    expect_rc 0 "includeIf $cond, run from $where"
    lacks "Invalid path" "includeIf $cond, run from $where"
    [ "$(get user.email)" = "me@example.com" ] || fail "includeIf $cond from $where: $(get user.email)"
  done
  # The two quiet modes read the same way: auto finds the host signing, and
  # check has no stale key to report.
  named
  rc=0
  out="$(cd "$HOME/work/r" && python3 -I -B "$module" --config-local "$local_cfg" --installer "$installer" \
    --mode auto 2>&1)" || rc=$?
  expect_rc 0 "includeIf $cond, auto mode"; [ -z "$out" ] || fail "includeIf $cond, auto mode spoke: $out"
  rc=0
  out="$(cd "$HOME/work/r" && python3 -I -B "$module" --config-local "$local_cfg" --installer "$installer" \
    --mode check 2>&1)" || rc=$?
  expect_rc 0 "includeIf $cond, check mode"; [ -z "$out" ] || fail "includeIf $cond, check mode spoke: $out"
  ok
done

# --- onbranch: never holds here; hasconfig: does, as it does for git --------
# Outside a repository there is no branch, while hasconfig:remote.*.url:
# matches the remotes of the global config itself. Neither makes git fail.
fresh
export FAKE_AGENT_KEYS="$K1"
printf 'me@example.com %s\n' "$K1" > "$signers"
printf 'evil@example.com %s\n' "$K1" > "$HOME/evil_signers"
printf '[user]\n\temail = evil@example.com\n' > "$XDG_CONFIG_HOME/git/evil.inc"
printf '[includeIf "onbranch:**"]\n\tpath = evil.inc\n' >> "$XDG_CONFIG_HOME/git/config"
git init -q -b main "$HOME/r"
[ "$(git -C "$HOME/r" config --get user.email)" = evil@example.com ] \
  || fail "onbranch: the fixture's condition does not hold inside a repository, so this case proves nothing"
rc=0; out="$(cd "$HOME/r" && "$installer" identity 2>&1)" || rc=$?
expect_rc 0 "includeIf onbranch:"; [ "$(get user.email)" = "me@example.com" ] || fail "onbranch: $(get user.email)"
rm -f "$local_cfg"
printf '[gpg]\n\tformat = openpgp\n' > "$XDG_CONFIG_HOME/git/hc.inc"
printf '[remote "origin"]\n\turl = https://example.com/r.git\n[includeIf "hasconfig:remote.*.url:https://example.com/**"]\n\tpath = hc.inc\n' \
  >> "$XDG_CONFIG_HOME/git/config"
rc=0; out="$(cd "$HOME" && "$installer" identity 2>&1)" || rc=$?
expect_rc 1 "includeIf hasconfig:"; has "gpg.format is 'openpgp', not ssh" "includeIf hasconfig: applies"
unwritten "includeIf hasconfig:"
ok

# --- D2: two principals, two keys, and the user.email filter -----------------
fresh
printf 'a@example.com,b@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
run; expect_rc 1 "two principals on one key"; has "more than one identity" "two principals"
has "a@example.com $FP1" "two principals: fingerprint named"; has "b@example.com $FP1" "two principals: both named"
unwritten "two principals"
# Once user.email names one of them, it is the filter, and the step proceeds.
printf '[user]\n\temail = b@example.com\n' > "$local_cfg"
run; expect_rc 0 "user.email selects among principals"
[ "$(get user.signingkey)" = "key::$K1" ] || fail "user.email filter: signingkey $(get user.signingkey)"
fresh
printf 'a@example.com %s\na@example.com %s\n' "$K1" "$K2" > "$signers"
export FAKE_AGENT_KEYS="$K1
$K2"
run; expect_rc 1 "two keys for one principal"; has "more than one ssh-agent key is listed for a@example.com" "two keys"
has "$FP1" "two keys: first fingerprint"; has "$FP2" "two keys: second fingerprint"
unwritten "two keys"
# Still two keys after the email filter (another principal's key drops out).
printf 'a@example.com %s\na@example.com %s\nz@example.com %s\n' "$K1" "$K2" "$K3" > "$signers"
printf '[user]\n\temail = a@example.com\n' > "$local_cfg"
export FAKE_AGENT_KEYS="$K1
$K2
$K3"
run; expect_rc 1 "two keys left after the email filter"; has "more than one ssh-agent key" "two keys after filter"
lacks "$FP3" "the filtered-out key is not named"
[ "$(get user.signingkey)" = "UNSET" ] || fail "two keys after filter wrote a signingkey"
ok

# --- the real host's shape: two entries for one email, the agent holds one ---
fresh
printf 'b@example.dev namespaces="git" %s old-laptop\nb@example.dev namespaces="git" %s this-host\n' "$K2" "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1 dotfiles-signing@this-host
$K3 an-unlisted-auth-key"
run
expect_rc 0 "host shape"
[ "$(get user.email)" = "b@example.dev" ] || fail "host shape: user.email $(get user.email)"
[ "$(get user.signingkey)" = "key::$K1" ] || fail "host shape: picked $(get user.signingkey)"
ok

# --- an RSA key listed under a signature algorithm name ---------------------
# ssh-keygen reads `rsa-sha2-256 <blob>` as the RSA key `ssh-rsa <blob>`, so
# the step counts it, and writes the canonical name that ssh-add -L prints.
fresh
ssh-keygen -q -t rsa -b 2048 -N '' -C rsa -f "$work/rsa_$n" </dev/null
KR="$(cut -d' ' -f1,2 "$work/rsa_$n.pub")"
printf 'me@example.com rsa-sha2-512 %s\n' "${KR#ssh-rsa }" > "$signers"
export FAKE_AGENT_KEYS="$KR"
run
expect_rc 0 "an RSA key under rsa-sha2-512"
[ "$(get user.signingkey)" = "key::$KR" ] || fail "rsa-sha2-512: signingkey $(get user.signingkey)"
# Beside a second key for the email, it is a second candidate, never skipped.
printf 'me@example.com rsa-sha2-256 %s\nme@example.com %s\n' "${KR#ssh-rsa }" "$K1" > "$signers"
rm -f "$local_cfg"
export FAKE_AGENT_KEYS="$KR
$K1"
run
expect_rc 1 "an aliased RSA key beside another key"
has "more than one ssh-agent key is listed for me@example.com" "the aliased RSA key counts"
unwritten "an aliased RSA key beside another key"
ok

# --- an existing different email is kept, and nothing is guessed for it -----
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
printf '[user]\n\temail = old@example.com\n' > "$local_cfg"
cp_before="$(cat "$local_cfg")"
run
expect_rc 1 "different email"
has "no ssh-agent key is listed for user.email old@example.com" "different email"
has "listed for this agent instead: me@example.com" "different email names the candidate"
[ "$(cat "$local_cfg")" = "$cp_before" ] || fail "different email: config.local changed"
[ ! -e "$local_cfg.bak" ] || fail "different email: a .bak with nothing written"
ok

# --- a different signingkey is kept; the same key as a path is not a conflict
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
mkdir -p "$HOME/.ssh"; printf '%s me@host\n' "$K1" > "$HOME/.ssh/id_signing.pub"
printf '[user]\n\temail = me@example.com\n\tsigningkey = ~/.ssh/id_signing.pub\n[commit]\n\tgpgsign = yes\n' > "$local_cfg"
run
expect_rc 0 "path signingkey for the same key"
[ "$(get user.signingkey)" = "~/.ssh/id_signing.pub" ] || fail "path signingkey was rewritten"
[ "$(get tag.gpgsign)" = "true" ] || fail "tag.gpgsign not added"
git config --file "$local_cfg" user.signingkey "key::$K2"
run
expect_rc 1 "different signingkey"
has "user.signingkey is already set to a different value - leaving it: key::$K2" "different signingkey"
[ "$(get user.signingkey)" = "key::$K2" ] || fail "different signingkey was overwritten"
ok

# --- a symlinked config.local is never replaced ------------------------------
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
: > "$work/real_local_$n"; ln -s "$work/real_local_$n" "$local_cfg"
run
expect_rc 1 "symlinked config.local"
[ -L "$local_cfg" ] || fail "the config.local symlink was replaced"
ok

# --- gpg.format must be ssh; config.local must be read by git -----------------
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
printf '[gpg]\n\tformat = openpgp\n[include]\n\tpath = config.local\n' > "$XDG_CONFIG_HOME/git/config"
run; expect_rc 1 "gpg.format openpgp"; has "gpg.format is 'openpgp', not ssh - writing nothing" "openpgp"
unwritten "gpg.format openpgp"
printf '[gpg]\n\tformat = ssh\n' > "$XDG_CONFIG_HOME/git/config"
run; expect_rc 1 "config.local not included"; has "git does not read $local_cfg" "include chain"
ok

# --- --rotate ----------------------------------------------------------------
fresh
printf 'me@example.com valid-before="20000101" %s\nme@example.com %s\n' "$K1" "$K2" > "$signers"
printf '[user]\n\temail = me@example.com\n\tsigningkey = key::%s\n[commit]\n\tgpgsign = true\n' "$K1" > "$local_cfg"
export FAKE_AGENT_KEYS="$K1
$K2"
# identity alone never replaces it, and reports it as stale.
run
expect_rc 1 "identity with a stale key"
has "user.signingkey $FP1 is not valid for me@example.com" "stale key reported"
has "run: $installer identity --rotate" "stale key: the fix is named"
[ "$(get user.signingkey)" = "key::$K1" ] || fail "identity replaced a signingkey"
run --rotate
expect_rc 0 "--rotate"
[ "$(get user.signingkey)" = "key::$K2" ] || fail "--rotate: signingkey $(get user.signingkey)"
has "$FP1 -> $FP2" "--rotate logs old and new fingerprints"
has "expired" "--rotate says why the old key went"
# The first .bak wins (it is the pristine file, from the identity run above),
# and it still holds the rotated-away key.
grep -qF "key::$K1" "$local_cfg.bak" || fail "--rotate: the .bak lost the old key"
[ "$(get user.email)" = "me@example.com" ] && [ "$(get commit.gpgsign)" = "true" ] \
  || fail "--rotate touched more than user.signingkey"
run --rotate
expect_rc 1 "--rotate with a valid key"; has "is still valid for me@example.com" "--rotate refuses a valid key"
# Two valid candidates: refuse.
printf 'me@example.com %s\nme@example.com %s\n' "$K2" "$K3" > "$signers"
git config --file "$local_cfg" user.signingkey "key::$K1"
export FAKE_AGENT_KEYS="$K2
$K3"
run --rotate
expect_rc 1 "--rotate with two candidates"; has "2 ssh-agent keys are valid for me@example.com" "two candidates"
[ "$(get user.signingkey)" = "key::$K1" ] || fail "--rotate wrote with two candidates"
# A signingkey that comes from outside config.local: refuse, name the origin.
fresh
printf 'me@example.com %s\n' "$K2" > "$signers"
export FAKE_AGENT_KEYS="$K2"
printf '[user]\n\temail = me@example.com\n' > "$local_cfg"
printf '[user]\n\tsigningkey = key::%s\n' "$K1" > "$HOME/.gitconfig"
run --rotate
expect_rc 1 "--rotate outside config.local"; has "comes from file:$HOME/.gitconfig" "origin named"
rm -f "$HOME/.gitconfig"
run --rotate
expect_rc 1 "--rotate with no signingkey"; has "user.signingkey is not set - nothing to rotate" "nothing to rotate"
ok

# --- stale-key report: not in the agent; set outside config.local ------------
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
printf '[user]\n\temail = me@example.com\n\tsigningkey = key::%s\n[commit]\n\tgpgsign = true\n[tag]\n\tgpgsign = true\n' "$K1" > "$local_cfg"
git config --file "$local_cfg" gpg.ssh.allowedSignersFile "$signers"
export FAKE_AGENT_KEYS="$K3"
advise() { rc=0; out="$(bash -c 'set -euo pipefail; . "$1"; _signing_advisory' _ "$installer" 2>&1)" || rc=$?; }
advise
expect_rc 0 "advisory"
has "user.signingkey $FP1 is not loaded in the ssh-agent - signing will fail" "not in the agent"
export FAKE_AGENT_KEYS="$K1"
advise
[ -z "$out" ] || fail "advisory not quiet on a healthy host: $out"
printf '[user]\n\tsigningkey = key::%s\n' "$K1" > "$HOME/.gitconfig"
advise
has "user.signingkey is set in file:$HOME/.gitconfig, outside $local_cfg" "signingkey outside config.local"
rm -f "$HOME/.gitconfig"; ln -s "$HOME/gone/gitconfig" "$HOME/.gitconfig"
advise
has "a dangling ~/.gitconfig symlink is in place" "dangling ~/.gitconfig"
rm -f "$HOME/.gitconfig"; printf '[alias]\n\tst = status\n' > "$HOME/.gitconfig"
advise
has "~/.gitconfig exists (no identity or signing settings); git config --global reads and writes only it" "present ~/.gitconfig"
rm -f "$HOME/.gitconfig"
ok

# --- auto mode: non-fatal, quiet once configured, never rotates --------------
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
idrun() { rc=0; out="$(bash -c 'set -euo pipefail; . "$1"; do_identity --mode auto' _ "$installer" 2>&1)" || rc=$?; }
# A host missing both the name and the email hears the cause first. A run
# that cannot write prints its one cause line, never the name line (main()
# keeps one line on a failure), and writes nothing.
FAKE_AGENT_DOWN=1 idrun; expect_rc 1 "auto mode with no agent, no name and no email"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "auto mode with no agent, no name and no email: want one line: $out"
has "identity: cannot reach an ssh-agent" "auto mode with no agent, no name and no email names the agent"
lacks "user.name" "auto mode with no agent, no name and no email"
unwritten "auto mode with no agent"
# A run that writes prints its wrote line, then the name line: two lines, in
# that order (rc 0 keeps every warning).
idrun; expect_rc 0 "auto mode writes"
[ "$(get user.email)" = "me@example.com" ] || fail "auto mode did not write"
[ "$(grep -c . <<<"$out")" -eq 2 ] || fail "auto mode writing on a host with no name: want two lines: $out"
grep -q '^install: identity: wrote user.email, ' <<<"$(sed -n 1p <<<"$out")" \
  || fail "auto mode writing on a host with no name: the wrote line comes first: $out"
grep -qF "identity: user.name is not set - run: $installer identity --name \"" <<<"$(sed -n 2p <<<"$out")" \
  || fail "auto mode writing on a host with no name: the name line comes second: $out"
export FAKE_AGENT_DOWN=1
# Everything but the name: the one line is the --name hint, never the agent
# the step does not need here, and the name is not written.
idrun; expect_rc 0 "auto mode on a host with no user.name"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "auto mode on a host with no user.name: want one line: $out"
has "identity: user.name is not set - run: $installer identity --name \"" "auto mode on a host with no user.name"
lacks "ssh-agent" "auto mode on a host with no user.name names the agent"
[ "$(get user.name)" = UNSET ] || fail "auto wrote user.name"
named
idrun; expect_rc 0 "auto mode on a configured host"
[ -z "$out" ] || fail "auto mode is not quiet on a configured host: $out"
unset FAKE_AGENT_DOWN
# A scrubbed global level (GIT_CONFIG_GLOBAL=/dev/null) is never read as absent.
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
rc=0; out="$(GIT_CONFIG_GLOBAL=/dev/null "$installer" identity 2>&1)" || rc=$?
expect_rc 1 "scrubbed global"; has "GIT_CONFIG_GLOBAL=/dev/null is not $XDG_CONFIG_HOME/git/config" "scrubbed global"
unwritten "a scrubbed global view"
# Wiring: install runs the step once, before the advisory; link runs it with
# the stale-key line; the upgrade arm reaches it only through the link child;
# nothing rotates.
arm_of() { awk -v a="  $1)" '$0 == a {p=1} p&&/^    ;;$/{exit} p' "$installer"; }
arm="$(arm_of install)"
[ "$(grep -c 'do_identity --mode auto || :' <<<"$arm")" -eq 1 ] || fail "the install arm must run the auto step exactly once"
id_line="$(grep -n 'do_identity --mode auto || :' <<<"$arm" | cut -d: -f1)"
adv_line="$(grep -n '^    _signing_advisory' <<<"$arm" | cut -d: -f1)"
[ -n "$adv_line" ] && [ "$id_line" -lt "$adv_line" ] || fail "the install arm must run the auto step before _signing_advisory"
! grep -qE 'install\.sh.* link|do_link_arm' <<<"$arm" || fail "the install arm must not re-enter the link arm (the step would run twice)"
[ "$(grep -c 'do_identity --mode auto --report-stale || :' <<<"$(arm_of link)")" -eq 1 ] || fail "the link arm must run the auto step, reporting a stale key"
! grep -q -- '--report-stale' <<<"$arm" || fail "the install arm leaves the stale key to _signing_advisory"
! grep -q 'do_identity' <<<"$(arm_of upgrade)" || fail "the upgrade arm must reach the step only through its link child"
! grep -q -- '--mode rotate' <<<"$(arm_of install)$(arm_of link)" || fail "install and link must never rotate"
ok

# --- through the real arms: link, install and dotfiles-upgrade ---------------
# A minimal real checkout (the installer, lib/, the tracked git config), so the
# link engine writes the real ~/.config/git/config with its includes.
fresh
rm -rf "$XDG_CONFIG_HOME/git"
export XDG_CACHE_HOME="$HOME/.cache" XDG_STATE_HOME="$HOME/.local/state"
A="$work/origin"
mkdir -p "$A/config/git" "$A/zsh"
cat "$repo_root/install.sh" > "$A/install.sh"; chmod u+x "$A/install.sh"
cp -R "$repo_root/lib" "$A/lib"
cat "$repo_root/config/git/config" > "$A/config/git/config"
cat "$repo_root/zsh/zshenv" > "$A/zsh/zshenv"; cat "$repo_root/zsh/zshrc" > "$A/zsh/zshrc"
git init -q "$A"
git -C "$A" add -A
git -C "$A" -c user.name=t -c user.email=t@x -c commit.gpgsign=false commit -q -m c1
B="$work/clone"; git clone -q "$A" "$B"; B="$(cd "$B" && pwd -P)"
export FAKE_AGENT_KEYS="$K1"
# install on a host with no trust root yet: the step refuses, install still succeeds.
rc=0; out="$(bash "$B/install.sh" install </dev/null 2>&1)" || rc=$?
expect_rc 0 "install with no allowed-signers file"
has "identity: no allowed-signers file found - writing nothing" "install runs the step"
[ "$(grep -c 'no allowed-signers file found' <<<"$out")" -eq 1 ] || fail "install ran the step more than once: $out"
unwritten "install with no trust root"
# link with a trust root: the identity is written through the real include chain.
printf 'me@example.com %s\n' "$K1" > "$signers"
rc=0; out="$(bash "$B/install.sh" link </dev/null 2>&1)" || rc=$?
expect_rc 0 "link writes the identity"
[ "$(git -C "$HOME" config --get user.email)" = "me@example.com" ] || fail "link: user.email not effective"
[ "$(git -C "$HOME" config --get user.signingkey)" = "key::$K1" ] || fail "link: user.signingkey not effective"
[ "$(get user.name)" = "UNSET" ] || fail "link wrote user.name"
# link on a keyed host with no user.name prints the identity --name line:
# one line, and config.local is left as it is.
before="$(ls -li "$local_cfg")"; content="$(cat "$local_cfg")"
rc=0; out="$(bash "$B/install.sh" link </dev/null 2>&1)" || rc=$?
expect_rc 0 "link on a keyed host with no user.name"
[ "$(grep -c 'identity:' <<<"$out")" -eq 1 ] || fail "link with no user.name printed more than one identity line: $out"
has "identity: user.name is not set - run: $B/install.sh identity --name \"" "link on a keyed host with no user.name prints the identity --name line"
[ "$(ls -li "$local_cfg")" = "$before" ] && [ "$(cat "$local_cfg")" = "$content" ] || fail "link with no user.name rewrote config.local"
named
before="$(ls -li "$local_cfg")"
rc=0; out="$(bash "$B/install.sh" link </dev/null 2>&1)" || rc=$?
expect_rc 0 "second link"; lacks "identity:" "second link is quiet"
[ "$(ls -li "$local_cfg")" = "$before" ] || fail "second link rewrote config.local"
# A refusal never changes link's exit status.
rm -f "$local_cfg"
rc=0; out="$(FAKE_AGENT_DOWN=1 bash "$B/install.sh" link </dev/null 2>&1)" || rc=$?
expect_rc 0 "link with the agent down"; has "cannot reach an ssh-agent" "link with the agent down"
unwritten "link with the agent down"
# dotfiles-upgrade: the new tree's link child writes the identity.
printf 'next\n' > "$A/NEXT"
git -C "$A" add NEXT
git -C "$A" -c user.name=t -c user.email=t@x -c commit.gpgsign=false commit -q -m c2
rc=0; out="$(bash "$B/install.sh" upgrade </dev/null 2>&1)" || rc=$?
expect_rc 0 "upgrade"; has "upgrade: done" "upgrade merged"
[ "$(git -C "$HOME" config --get user.signingkey)" = "key::$K1" ] || fail "upgrade did not write the identity: $out"
named
before="$(ls -li "$local_cfg")"
rc=0; out="$(bash "$B/install.sh" upgrade </dev/null 2>&1)" || rc=$?
expect_rc 0 "second upgrade"; lacks "identity:" "second upgrade is quiet"
[ "$(ls -li "$local_cfg")" = "$before" ] || fail "second upgrade rewrote config.local"
# The configured key goes stale: link and upgrade say so in ONE line, naming
# the full installer path, and still exit 0 without touching config.local.
printf 'me@example.com valid-before="20000101" %s\n' "$K1" > "$signers"
rc=0; out="$(bash "$B/install.sh" link </dev/null 2>&1)" || rc=$?
expect_rc 0 "link with a stale key"
[ "$(grep -c 'identity:' <<<"$out")" -eq 1 ] || fail "link printed more than one identity line: $out"
has "identity: user.signingkey $FP1 is not valid for me@example.com in $signers (line 1: expired) - run $B/install.sh identity --rotate" "link names the stale key"
[ "$(ls -li "$local_cfg")" = "$before" ] || fail "link with a stale key rewrote config.local"
# A missing user.name line wins over a stale-key line: git refuses every
# commit without the name, while the stale key only leaves new signatures
# unverified. Once the name is back, the stale key is reported again.
git config --file "$local_cfg" --unset user.name
rc=0; out="$(bash "$B/install.sh" link </dev/null 2>&1)" || rc=$?
expect_rc 0 "link with a stale key and no user.name"
[ "$(grep -c 'identity:' <<<"$out")" -eq 1 ] || fail "link with a stale key and no name printed more than one identity line: $out"
has "identity: user.name is not set - run: $B/install.sh identity --name \"" "a missing user.name line wins over a stale-key line"
named
before="$(ls -li "$local_cfg")"
printf 'c3\n' > "$A/NEXT"
git -C "$A" -c user.name=t -c user.email=t@x -c commit.gpgsign=false commit -q -am c3
rc=0; out="$(bash "$B/install.sh" upgrade </dev/null 2>&1)" || rc=$?
expect_rc 0 "upgrade with a stale key"; has "upgrade: done" "upgrade with a stale key merged"
[ "$(grep -c 'identity:' <<<"$out")" -eq 1 ] || fail "upgrade printed more than one identity line: $out"
has "is not valid for me@example.com" "upgrade names the stale key"
# Revoked rather than expired: the same one line, naming the revocation.
printf 'me@example.com %s\n' "$K1" > "$signers"
printf '%s\n' "$K1" > "$HOME/revoked"
git config --file "$local_cfg" gpg.ssh.revocationFile "$HOME/revoked"
before="$(ls -li "$local_cfg")"
rc=0; out="$(bash "$B/install.sh" link </dev/null 2>&1)" || rc=$?
expect_rc 0 "link with a revoked key"
[ "$(grep -c 'identity:' <<<"$out")" -eq 1 ] || fail "link printed more than one identity line: $out"
has "(revoked by gpg.ssh.revocationFile) - run $B/install.sh identity --rotate" "link names the revocation"
# A revocation file ssh-keygen cannot read: one line, pointing at the details.
printf 'SSHKRL\n\0garbage' > "$HOME/revoked"
rc=0; out="$(bash "$B/install.sh" link </dev/null 2>&1)" || rc=$?
expect_rc 0 "link with an unreadable KRL"
has "(the revocation file cannot be checked) - see $B/install.sh identity" "link names the unreadable KRL"
[ "$(ls -li "$local_cfg")" = "$before" ] || fail "a stale report rewrote config.local"
# config.local turns signing on and ~/.gitconfig turns it off again: not the
# host's exception, so link says so in one line, and still exits 0. The true
# is set by hand: the step no longer writes it beside the tracked true, but a
# host that ran an earlier release keeps the copy it wrote then.
git config --file "$local_cfg" --unset gpg.ssh.revocationFile
git config --file "$local_cfg" commit.gpgsign true
before="$(ls -li "$local_cfg")"; content="$(cat "$local_cfg")"
printf '[commit]\n\tgpgsign = false\n' > "$HOME/.gitconfig"
rc=0; out="$(bash "$B/install.sh" link </dev/null 2>&1)" || rc=$?
expect_rc 0 "link with signing overridden off"
[ "$(grep -c 'identity:' <<<"$out")" -eq 1 ] || fail "link printed more than one identity line: $out"
has "identity: signing is off against $local_cfg: commit.gpgsign = false from file:$HOME/.gitconfig - see $B/install.sh identity" "link names the override"
[ "$(ls -li "$local_cfg")" = "$before" ] && [ "$(cat "$local_cfg")" = "$content" ] || fail "an override report rewrote config.local"
rm -f "$HOME/.gitconfig"
# An opted-out host (commit.gpgsign = false in config.local) is quiet on link
# and upgrade, with no agent and a stale key alike, and nothing is written:
# tag.gpgsign is never turned on for it.
printf '[user]\n\temail = me@example.com\n[commit]\n\tgpgsign = false\n' > "$local_cfg"
before="$(ls -li "$local_cfg")"; content="$(cat "$local_cfg")"
# An opted-out host with no user.name hears nothing from auto: doctor, below,
# is where it learns that git refuses every commit without one.
[ "$(get user.name)" = UNSET ] || fail "the opted-out fixture has a user.name"
rc=0; out="$(FAKE_AGENT_DOWN=1 bash "$B/install.sh" link </dev/null 2>&1)" || rc=$?
expect_rc 0 "link on an opted-out host with no agent"; lacks "identity:" "an opted-out host with no user.name hears nothing from auto"
printf 'me@example.com valid-before="20000101" %s\n' "$K1" > "$signers"
git config --file "$local_cfg" user.signingkey "key::$K1"
before="$(ls -li "$local_cfg")"; content="$(cat "$local_cfg")"
rc=0; out="$(bash "$B/install.sh" link </dev/null 2>&1)" || rc=$?
expect_rc 0 "link on an opted-out host with a stale key"; lacks "identity:" "link on an opted-out, stale host is quiet"
printf 'c4\n' > "$A/NEXT"
git -C "$A" -c user.name=t -c user.email=t@x -c commit.gpgsign=false commit -q -am c4
rc=0; out="$(FAKE_AGENT_DOWN=1 bash "$B/install.sh" upgrade </dev/null 2>&1)" || rc=$?
expect_rc 0 "upgrade on an opted-out host"; has "upgrade: done" "upgrade on an opted-out host merged"
lacks "identity:" "upgrade on an opted-out host is quiet"
[ "$(ls -li "$local_cfg")" = "$before" ] && [ "$(cat "$local_cfg")" = "$content" ] || fail "an opted-out host's config.local was rewritten"
[ "$(get tag.gpgsign)" = UNSET ] || fail "tag.gpgsign was turned on for an opted-out host"
# doctor on that host: the missing name is still a problem (every commit
# carries it); once it is set, silent and 0; --verbose names the opt-out.
rc=0; out="$(bash "$B/install.sh" doctor </dev/null 2>&1)" || rc=$?
expect_rc 1 "doctor on an opted-out host with no name"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "doctor on an opted-out host with no name: want one line: $out"
has "doctor: values: user.name is not set" "doctor on an opted-out host still needs user.name"
git config --file "$local_cfg" user.name "Jane Doe"
before="$(ls -li "$local_cfg")"; content="$(cat "$local_cfg")"
rc=0; out="$(bash "$B/install.sh" doctor </dev/null 2>&1)" || rc=$?
expect_rc 0 "doctor on an opted-out host"; [ -z "$out" ] || fail "doctor is not silent on an opted-out host: $out"
rc=0; out="$(bash "$B/install.sh" doctor --verbose </dev/null 2>&1)" || rc=$?
expect_rc 0 "doctor --verbose on an opted-out host"
has "doctor: values: commit.gpgsign = false from file:$local_cfg: respected as this host's opt-out; the automatic step stays quiet and writes nothing" "doctor --verbose names the opt-out with its origin"
has "doctor: verdict: signing is off on purpose on this host; nothing needs action" "doctor --verbose verdict on an opted-out host"
[ "$(ls -li "$local_cfg")" = "$before" ] && [ "$(cat "$local_cfg")" = "$content" ] || fail "doctor rewrote config.local"
rm -f "$local_cfg"
unset XDG_CACHE_HOME XDG_STATE_HOME
ok

# --- an override at another level is never "already configured" ------------
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
run; expect_rc 0 "override: first run"
printf '[user]\n\tsigningkey = key::%s\n' "$K2" > "$HOME/.gitconfig"
run
expect_rc 1 "override by ~/.gitconfig"
has "user.signingkey is overridden by file:$HOME/.gitconfig - leaving it: key::$K2" "override named with its origin"
lacks "already configured" "an override is not reported as configured"
rm -f "$HOME/.gitconfig"
ok

# --- an explicit false is the host's exception: kept, the rest still written --
# (operator decision: a commit.gpgsign or tag.gpgsign = false at any level is
# kept; email and key are written anyway; key, email or trust-root conflicts
# still write nothing. Only a commit.gpgsign = false in config.local opts the
# host out of signing; a false at another level is the exception alone.)
for where in local global; do
  for key in commit.gpgsign tag.gpgsign; do
    fresh
    printf 'me@example.com %s\n' "$K1" > "$signers"
    export FAKE_AGENT_KEYS="$K1"
    if [ "$where" = local ]; then file="$local_cfg"; else file="$HOME/.gitconfig"; fi
    git config --file "$file" "$key" false
    run
    expect_rc 0 "$key = false in $where"
    has "identity: $key is false (file:$file) - kept as this host's exception, so it stays off" "$key = false in $where is named, with its origin"
    [ "$(get user.email)" = "me@example.com" ] && [ "$(get user.signingkey)" = "key::$K1" ] \
      || fail "$key = false in $where: email and key not written"
    [ "$(git -C "$HOME" config --type=bool --get "$key")" = false ] || fail "$key = false in $where was not kept"
    # commit.gpgsign = false in config.local opts the host out: tag.gpgsign
    # is not turned on for it either. Anywhere else it is not an opt-out, so
    # tag.gpgsign is written as before. tag.gpgsign = false alone still gets
    # commit signing.
    if [ "$key" = commit.gpgsign ] && [ "$where" = local ]; then
      [ "$(get tag.gpgsign)" = UNSET ] || fail "commit.gpgsign = false in $where: tag.gpgsign written"
      has "identity: tag.gpgsign is left unset while commit.gpgsign is false (this host opted out of signing)" "an opted-out host is told why tag.gpgsign stays unset"
    elif [ "$key" = commit.gpgsign ]; then
      [ "$(get tag.gpgsign)" = true ] || fail "commit.gpgsign = false in $where: tag.gpgsign not written"
      lacks "tag.gpgsign is left unset" "a false outside config.local is not an opt-out"
    else
      # Commit signing stays on from the tracked true, and is not copied.
      [ "$(git -C "$HOME" config --type=bool --get commit.gpgsign)" = true ] \
        || fail "$key = false in $where: commit signing is not on"
      [ "$(get commit.gpgsign)" = UNSET ] || fail "$key = false in $where: commit.gpgsign written beside the tracked true"
    fi
    if [ "$where" = global ]; then [ "$(get "$key")" = UNSET ] || fail "$key written beside a global false"; fi
    # Quiet afterwards, through the automatic step too, once the host has
    # the name the step never writes.
    named
    idrun; expect_rc 0 "auto after $key = false in $where"; [ -z "$out" ] || fail "auto not quiet: $out"
  done
done
# The automatic step on an opted-out host (commit.gpgsign = false in
# config.local) writes nothing and says nothing, for every spelling git reads
# as false.
for spelling in false no off 0 FALSE; do
  fresh
  printf 'me@example.com %s\n' "$K1" > "$signers"
  export FAKE_AGENT_KEYS="$K1"
  printf '[commit]\n\tgpgsign = %s\n' "$spelling" > "$local_cfg"
  idrun
  expect_rc 0 "auto on a host opted out with $spelling"
  [ -z "$out" ] || fail "auto is not quiet on a host opted out with $spelling: $out"
  [ "$(cat "$local_cfg")" = "$(printf '[commit]\n\tgpgsign = %s' "$spelling")" ] \
    || fail "auto wrote to a host opted out with $spelling: $(cat "$local_cfg")"
done
# A false in config.local beside tag.gpgsign = true is not an opt-out: tags
# still sign, so the automatic step still writes the identity and reports
# the false as the host's exception.
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
printf '[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = true\n' > "$local_cfg"
idrun
expect_rc 0 "auto beside a config.local false and a true tag.gpgsign"
has "identity: wrote user.email" "a true tag.gpgsign keeps the automatic step writing"
has "identity: commit.gpgsign is false (file:$local_cfg) - kept as this host's exception" "auto reports the false beside a true tag.gpgsign"
[ "$(get user.email)" = me@example.com ] && [ "$(get tag.gpgsign)" = true ] \
  || fail "auto beside a config.local false and a true tag.gpgsign: $(cat "$local_cfg")"
# A false at any other level is not an opt-out: the automatic step still
# writes the identity and names the exception with its file, for
# ~/.gitconfig and a file a plain [include] pulls in after the tracked config.
# (A system-level false is read before the tracked true and loses: below.)
for level in gitconfig include; do
  fresh
  printf 'me@example.com %s\n' "$K1" > "$signers"
  export FAKE_AGENT_KEYS="$K1"
  case "$level" in
    gitconfig) file="$HOME/.gitconfig" ;;
    include) file="$HOME/included"
      printf '[include]\n\tpath = %s\n' "$file" >> "$XDG_CONFIG_HOME/git/config" ;;
  esac
  printf '[commit]\n\tgpgsign = false\n' > "$file"
  idrun
  expect_rc 0 "auto beside a false from $level"
  has "identity: wrote user.email" "auto writes beside a false from $level"
  has "identity: commit.gpgsign is false (file:$file) - kept as this host's exception, so it stays off" "auto names the exception from $level"
  [ "$(get tag.gpgsign)" = true ] || fail "a false from $level opted the host out of tag.gpgsign"
done
# A system-level false is read before the tracked true, so commits stay
# signed: no exception to name, and the step writes as on any host.
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
printf '[commit]\n\tgpgsign = false\n' > "$HOME/system-gitconfig"
rc=0; out="$(GIT_CONFIG_SYSTEM="$HOME/system-gitconfig" bash -c 'set -euo pipefail; . "$1"; do_identity --mode auto' _ "$installer" 2>&1)" || rc=$?
expect_rc 0 "auto beside a system-level false"
has "identity: wrote user.email" "auto writes beside a system-level false"
lacks "kept as this host's exception" "a system-level false that loses to the tracked true is not the exception"
[ "$(GIT_CONFIG_SYSTEM="$HOME/system-gitconfig" git -C "$HOME" config --type=bool --get commit.gpgsign)" = true ] \
  || fail "a system-level false turned commit signing off over the tracked true"
# A tag.gpgsign = false alone is not an opt-out: the step writes, and names it.
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
printf '[tag]\n\tgpgsign = false\n' > "$HOME/.gitconfig"
idrun
expect_rc 0 "auto writes beside a tag.gpgsign false"
has "identity: wrote user.email" "auto writes beside a tag.gpgsign false"
has "identity: tag.gpgsign is false (file:$HOME/.gitconfig) - kept as this host's exception, so it stays off" "auto names the exception when it writes"
rm -f "$HOME/.gitconfig"
# A key conflict still blocks everything, false or not.
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
printf '[commit]\n\tgpgsign = false\n[user]\n\tsigningkey = key::%s\n' "$K2" > "$local_cfg"
run
expect_rc 1 "a false beside a key conflict"
has "user.signingkey is already set to a different value" "the key conflict is named"
has "commit.gpgsign is false (file:$local_cfg) - kept as this host's exception" "a direct run names the exception even when it refuses"
[ "$(get user.email)" = UNSET ] || fail "a key conflict next to a false still wrote user.email"
# The automatic step leaves an opted-out host alone, conflict or not.
idrun
expect_rc 0 "auto, a false beside a key conflict"
[ -z "$out" ] || fail "auto is not quiet on an opted-out host with a key conflict: $out"
# With tag.gpgsign = false instead, the automatic step refuses in ONE line:
# the exception line is said only when the step goes on to write.
printf '[tag]\n\tgpgsign = false\n[user]\n\tsigningkey = key::%s\n' "$K2" > "$local_cfg"
idrun
expect_rc 1 "auto, a tag.gpgsign false beside a key conflict"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "auto printed more than one line beside an exception: $out"
lacks "kept as this host's exception" "auto does not print the exception line when it refuses"
printf '[commit]\n\tgpgsign = false\n[user]\n\tsigningkey = key::%s\n' "$K2" > "$local_cfg"
advise() { rc=0; out="$(bash -c 'set -euo pipefail; . "$1"; _signing_advisory' _ "$installer" 2>&1)" || rc=$?; }
printf '[commit]\n\tgpgsign = false\n' > "$HOME/.gitconfig"
advise
has "commit signing is NOT enabled on this host (commit.gpgsign is false)." "advisory names the actual value"
has "An explicit false from file:$HOME/.gitconfig is kept as this host's exception" "advisory names the exception and its file"
has "~/.gitconfig sets commit.gpgsign, and git reads it after ~/.config/git/config" "advisory warns about the ~/.gitconfig with signing off"
# A false outside config.local does not silence the stale-key report: a key
# can go stale while commit signing is off.
printf '[user]\n\temail = me@example.com\n\tsigningkey = key::%s\n[commit]\n\tgpgsign = false\n' "$K1" > "$local_cfg"
printf 'me@example.com valid-before="20000101" %s\n' "$K1" > "$signers"
advise
has "kept as this host's exception" "advisory names the exception"
has "user.signingkey $FP1 is not valid for me@example.com" "the stale key is reported beside an explicit false"
# The same host with the false in config.local alone has opted out: the
# advisory says nothing, stale key and missing agent included.
rm -f "$HOME/.gitconfig"
FAKE_AGENT_DOWN=1 advise
expect_rc 0 "advisory on an opted-out host"
[ -z "$out" ] || fail "the advisory is not silent on an opted-out host: $out"
# ...unless tag.gpgsign is true: tags still sign, so the key is still checked.
git config --file "$local_cfg" tag.gpgsign true
advise
has "tag.gpgsign is true, so tags are still signed" "a true tag.gpgsign is not an opt-out"
has "user.signingkey $FP1 is not valid for me@example.com" "the stale key is reported while tags sign"
git config --file "$local_cfg" --unset tag.gpgsign
printf 'me@example.com %s\n' "$K1" > "$signers"
# A true in config.local overridden by a later false is not the exception,
# for tag.gpgsign as for commit.gpgsign; the check names the file.
printf '[commit]\n\tgpgsign = true\n[tag]\n\tgpgsign = true\n' > "$local_cfg"
printf '[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n' > "$HOME/.gitconfig"
advise
has "identity: commit.gpgsign is true in $local_cfg, but file:$HOME/.gitconfig sets it false and wins - signing stays off" "advisory names a commit.gpgsign override"
has "identity: tag.gpgsign is true in $local_cfg, but file:$HOME/.gitconfig sets it false and wins - signing stays off" "advisory names a tag.gpgsign override"
lacks "exception" "an override is not called the exception"
printf '[commit]\n\tgpgsign = false\n' > "$HOME/.gitconfig"
printf '[commit]\n\tgpgsign = true\n' > "$local_cfg"
run
expect_rc 1 "identity with config.local true overridden by a later false"
has "commit.gpgsign is overridden by file:$HOME/.gitconfig - leaving it: false" "identity names the override"
lacks "kept as this host's exception" "identity does not call an override the exception"
[ "$(get user.email)" = UNSET ] || fail "an override still let the step write"
# The reverse: config.local false, a later true wins. Nothing to write for it.
printf 'me@example.com %s\n' "$K1" > "$signers"
printf '[commit]\n\tgpgsign = false\n' > "$local_cfg"
printf '[commit]\n\tgpgsign = true\n' > "$HOME/.gitconfig"
run
expect_rc 0 "config.local false, ~/.gitconfig true"
has "identity: commit.gpgsign is false in $local_cfg, but file:$HOME/.gitconfig sets it true and wins" "the reverse case is named"
lacks "kept as this host's exception" "a false that loses is not the exception"
[ "$(get commit.gpgsign)" = false ] || fail "the reverse case rewrote commit.gpgsign"
rm -f "$HOME/.gitconfig"
ok

# --- a false in the checkout's own config.local: the exception, not an opt-out
# The layout older installs used put config.local beside the tracked config,
# which still includes it by a relative path. Its false turns signing off but
# is not this host's opt-out (Host.is_local_origin()): doctor reports it as a
# problem, the advisory keeps it as the host's exception, and the automatic
# step never says every commit fails, writes beside it, then stays quiet.
fresh
export FAKE_AGENT_KEYS="$K1"
legacy="$work/tracked/config/git/config.local"
printf '[commit]\n\tgpgsign = false\n' > "$legacy"
rm -f "$signers"
idrun
expect_rc 1 "auto beside a repo-side false, no trust root"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "auto beside a repo-side false printed more than one line: $out"
lacks "every commit fails" "a repo-side false leaves commits possible, so auto does not say they fail"
printf 'me@example.com %s\n' "$K1" > "$signers"
idrun
expect_rc 0 "auto beside a repo-side false"
has "identity: wrote user.email" "a repo-side false is not an opt-out: auto still writes"
has "identity: commit.gpgsign is false (file:$legacy) - kept as this host's exception, so it stays off" "auto names the repo-side false as the exception"
named
idrun; expect_rc 0 "auto again beside a repo-side false"
[ -z "$out" ] || fail "auto is not quiet on a configured host with a repo-side false: $out"
rc=0; out="$(python3 -I -B "$module" --config-local "$local_cfg" --installer "$installer" --mode check 2>&1)" || rc=$?
expect_rc 0 "check beside a repo-side false"
has "An explicit false from file:$legacy is kept as this host's exception" "check keeps a repo-side false as the exception"
rc=0; out="$(cd "$HOME" && "$installer" doctor 2>&1)" || rc=$?
expect_rc 1 "doctor beside a repo-side false"
has "doctor: values: commit.gpgsign = false from file:$legacy, outside $local_cfg, so commits are not signed" "doctor reports a repo-side false as a problem"
lacks "opt-out;" "doctor does not take a repo-side false for the opt-out"
rm -f "$legacy"
ok

# --- config.local must be in the include chain BEFORE anything is written -----
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
printf '[gpg]\n\tformat = ssh\n' > "$XDG_CONFIG_HOME/git/config"
printf '[user]\n\temail = me@example.com\n' > "$HOME/.gitconfig"
run
expect_rc 1 "config.local not included, email from ~/.gitconfig"
has "git does not read $local_cfg (no [include] reaches it) - writing nothing" "include chain checked first"
unwritten "an unread config.local"
rm -f "$HOME/.gitconfig"
# A GIT_CONFIG_GLOBAL that only spells /dev/null differently is refused too.
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
rc=0; out="$(GIT_CONFIG_GLOBAL=/dev/./null "$installer" identity 2>&1)" || rc=$?
expect_rc 1 "GIT_CONFIG_GLOBAL=/dev/./null"; has "so git would not read $local_cfg" "a respelled /dev/null"
unwritten "a respelled /dev/null"
# ...while the XDG config itself, named explicitly, is fine.
rc=0; out="$(GIT_CONFIG_GLOBAL="$XDG_CONFIG_HOME/git/config" "$installer" identity 2>&1)" || rc=$?
expect_rc 0 "GIT_CONFIG_GLOBAL naming the XDG config"
ok

# --- gpg.ssh.revocationFile: a revoked key is never selected or kept ---------
fresh
printf 'me@example.com %s\nme@example.com %s\n' "$K1" "$K2" > "$signers"
export FAKE_AGENT_KEYS="$K1
$K2"
printf '%s revoked-host\n' "$K2" > "$HOME/revoked"
git config --file "$XDG_CONFIG_HOME/git/config" gpg.ssh.revocationFile '~/revoked'
run
expect_rc 0 "a revoked key drops out of the candidates"
[ "$(get user.signingkey)" = "key::$K1" ] || fail "revocation: picked $(get user.signingkey)"
# The configured key revoked later: reported, and --rotate replaces it.
printf '%s x\n' "$K2" > "$work/k2.pub"
printf '%s revoked-now\n' "$K1" > "$HOME/revoked"
printf 'me@example.com %s\n' "$K3" >> "$signers"
export FAKE_AGENT_KEYS="$K1
$K3"
run
expect_rc 1 "a revoked configured key"
has "user.signingkey $FP1 is not valid for me@example.com" "revoked key reported"
has "revoked by gpg.ssh.revocationFile" "revocation named as the reason"
run --rotate
expect_rc 0 "--rotate away from a revoked key"
[ "$(get user.signingkey)" = "key::$K3" ] || fail "rotate from revoked: $(get user.signingkey)"
# A KRL, read through ssh-keygen -Q.
printf '%s x\n' "$K3" > "$work/k3.pub"
rm -f "$HOME/revoked"; ssh-keygen -q -k -f "$HOME/revoked" "$work/k3.pub"
run
expect_rc 1 "a KRL revoking the configured key"; has "revoked by gpg.ssh.revocationFile" "KRL read"
# Set but unreadable, or holding a line that is not a key: write nothing.
rm -f "$local_cfg"
git config --file "$XDG_CONFIG_HOME/git/config" gpg.ssh.revocationFile '~/missing'
run; expect_rc 1 "missing revocation file"; has "cannot read gpg.ssh.revocationFile" "missing revocation file"
unwritten "a missing revocation file"
printf 'not a key\n' > "$HOME/bad_revoked"
git config --file "$XDG_CONFIG_HOME/git/config" gpg.ssh.revocationFile '~/bad_revoked'
run; expect_rc 1 "garbage revocation file"; has "line 1 is not a public key - writing nothing" "garbage revocation file"
unwritten "a garbage revocation file"
ok

# --- names: quoting, --name=VALUE, a leading dash, a different existing name -
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
run --name 'Jane "JJ" O\Doe'
expect_rc 0 "--name with quotes and a backslash"
[ "$(get user.name)" = 'Jane "JJ" O\Doe' ] || fail "--name quoting: [$(get user.name)]"
rm -f "$local_cfg" "$local_cfg.bak"
run --name=--Dash
expect_rc 0 "--name=VALUE with a leading dash"
[ "$(get user.name)" = "--Dash" ] || fail "--name=--Dash: [$(get user.name)]"
run --name "Someone Else"
expect_rc 1 "a different existing user.name"
has "user.name is already set to a different value - leaving it: --Dash" "different name kept"
run --name "$(printf 'Jane\342\200\213Doe')"
expect_rc 2 "--name with a zero-width space"
ok

# --- principals the step can never write -------------------------------------
fresh
export FAKE_AGENT_KEYS="$K1"
for p in '"me @example.com"' "$(printf '"me\t@example.com"')" \
  "$(printf 'me\342\200\213@example.com')" 'me@[example].com'; do
  printf '%s %s\n' "$p" "$K1" > "$signers"
  run
  expect_rc 1 "principal [$p]"; has "no ssh-agent key is listed for the git namespace" "principal [$p]"
  unwritten "principal [$p]"
done
# The escaped quote ends the quoted principal (`me\`); the quote after
# `@example.com` then opens an options field that never closes, so the line is
# malformed, and since it names the agent's key, an ambiguity.
printf '%s %s\n' '"me\"@example.com"' "$K1" > "$signers"
run
expect_rc 1 "principal with an escaped quote"
has "malformed allowed-signers line(s) 1 in $signers name an ssh-agent key - writing nothing" "escaped quote"
unwritten "principal with an escaped quote"
ok

# --- the allowed-signers file itself: CRLF, BOM, duplicates, odd files -------
fresh
export FAKE_AGENT_KEYS="$K1"
printf '# hosts\r\nme@example.com %s\r\nme@example.com %s\r\n' "$K1" "$K1" > "$signers"
run; expect_rc 0 "CRLF line ends and a duplicate line"
[ "$(get user.signingkey)" = "key::$K1" ] || fail "CRLF: $(get user.signingkey)"
rm -f "$local_cfg"
printf '\357\273\277me@example.com %s\n' "$K1" > "$signers"
run; expect_rc 1 "a byte-order mark on the only line"; unwritten "a BOM line"
rm -f "$signers"; mkdir "$signers"
run; expect_rc 1 "a directory"; has "not a regular file - writing nothing" "a directory"
rmdir "$signers"; mkfifo "$signers"
run; expect_rc 1 "a FIFO"; has "not a regular file - writing nothing" "a FIFO (no hang)"
rm -f "$signers"; printf 'me@example.com %s\n' "$K1" > "$signers"; chmod 000 "$signers"
run; expect_rc 1 "an unreadable file"; has "cannot read the allowed-signers file" "unreadable"
chmod 600 "$signers"
unwritten "an unusable allowed-signers file"
ok

# --- a signingkey in ~/.gitconfig with no config.local ------------------------
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
printf '[user]\n\tsigningkey = key::%s\n' "$K2" > "$HOME/.gitconfig"
run
expect_rc 1 "a foreign signingkey in ~/.gitconfig"
has "user.signingkey is already set to a different value - leaving it: key::$K2" "foreign signingkey kept"
has "user.signingkey is set in file:$HOME/.gitconfig, outside $local_cfg" "its origin is named"
lacks "the last one git reads wins" "one origin is not called a competition"
[ "$(get user.signingkey)" = "UNSET" ] || fail "a signingkey was written next to a foreign one"
idrun
expect_rc 1 "auto with a foreign signingkey"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "auto mode printed more than one line: $out"
has "(details: $installer identity)" "auto mode points at the full installer path"
rm -f "$HOME/.gitconfig"
ok

# --- --rotate refusals: agent, symlink, scrubbed global ----------------------
fresh
printf 'me@example.com valid-before="20000101" %s\nme@example.com %s\n' "$K1" "$K2" > "$signers"
printf '[user]\n\temail = me@example.com\n\tsigningkey = key::%s\n' "$K1" > "$local_cfg"
FAKE_AGENT_DOWN=1 run --rotate; expect_rc 1 "--rotate, agent down"; has "cannot reach an ssh-agent" "--rotate, agent down"
FAKE_AGENT_KEYS="" run --rotate; expect_rc 1 "--rotate, agent empty"; has "the ssh-agent holds no keys" "--rotate, agent empty"
rc=0; out="$(GIT_CONFIG_GLOBAL=/dev/null "$installer" identity --rotate 2>&1)" || rc=$?
expect_rc 1 "--rotate under a scrubbed global"; has "GIT_CONFIG_GLOBAL=/dev/null is not" "--rotate, scrubbed global"
export FAKE_AGENT_KEYS="$K2"
mv "$local_cfg" "$work/rot_real"; ln -s "$work/rot_real" "$local_cfg"
run --rotate
expect_rc 1 "--rotate through a symlink"; has "refusing to write through the symlink" "--rotate, symlink"
[ -L "$local_cfg" ] && grep -qF "key::$K1" "$work/rot_real" || fail "--rotate changed a symlinked config.local"
ok

# --- auto mode: one line per refusal; quiet on a configured (even stale) host
fresh
export FAKE_AGENT_KEYS="$K1"
rm -f "$signers"
idrun
expect_rc 1 "auto, no trust root"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "auto mode printed more than one line: $out"
# The tracked commit.gpgsign = true with no key left: the one line says
# every commit fails, and how out, in place of the bare details pointer.
has "identity: no allowed-signers file found - writing nothing; every commit fails until this host has a signing key - run $installer identity on this host, or opt it out of signing (see docs/signing-key.md)" "auto one line names that every commit fails"
printf 'me@example.com %s\n' "$K1" > "$signers"
rc=0; out="$(SSH_CONNECTION='10.0.0.1 22 10.0.0.2 22' bash -c 'set -euo pipefail; . "$1"; do_identity --mode auto' _ "$installer" 2>&1)" || rc=$?
expect_rc 1 "auto in an SSH session"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "auto over SSH printed more than one line: $out"
has "identity: not set automatically in an SSH session (a forwarded agent holds another machine's keys); every commit fails until this host has a signing key - run $installer identity on this host, or opt it out of signing (see docs/signing-key.md)" \
  "auto on an SSH session names that commits fail until identity runs"
unwritten "auto in an SSH session"
rc=0; out="$(SSH_CONNECTION='10.0.0.1 22 10.0.0.2 22' "$installer" identity 2>&1)" || rc=$?
expect_rc 0 "an explicit identity run in an SSH session"
named
# A configured host whose key went stale: auto without --report-stale (the
# install arm, whose advisory reports it in full) stays quiet; with it (the
# link arm) it prints one line, in an SSH session too, since it only reads.
printf 'me@example.com valid-before="20000101" %s\n' "$K1" > "$signers"
idrun; expect_rc 0 "auto, stale key"; [ -z "$out" ] || fail "auto mode is not quiet on a stale configured host: $out"
rc=0; out="$(SSH_CONNECTION='10.0.0.1 22 10.0.0.2 22' bash -c 'set -euo pipefail; . "$1"; do_identity --mode auto --report-stale' _ "$installer" 2>&1)" || rc=$?
expect_rc 1 "auto --report-stale, stale key"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "auto --report-stale printed more than one line: $out"
has "is not valid for me@example.com in $signers (line 1: expired) - run $installer identity --rotate" "the stale line"
rc=0; out="$("$installer" identity --rotate --report-stale 2>&1)" || rc=$?
expect_rc 2 "--report-stale is not an identity option"
rc=0; out="$(python3 -I "$module" --config-local "$local_cfg" --mode check --report-stale 2>&1)" || rc=$?
expect_rc 2 "--report-stale outside --mode auto"; has "taken only by --mode auto" "--report-stale outside auto"
# Already configured as git sees it, under a GIT_CONFIG_GLOBAL that is not the
# XDG config: nothing to write, so the guard that protects writing stays out.
printf 'me@example.com %s\n' "$K1" > "$signers"
other_global="$HOME/other_global"
printf '[user]\n\tname = Jane Doe\n\temail = me@example.com\n\tsigningkey = key::%s\n[commit]\n\tgpgsign = true\n' "$K1" > "$other_global"
rc=0; out="$(GIT_CONFIG_GLOBAL="$other_global" bash -c 'set -euo pipefail; . "$1"; do_identity --mode auto --report-stale' _ "$installer" 2>&1)" || rc=$?
expect_rc 0 "auto on a configured host under another GIT_CONFIG_GLOBAL"
[ -z "$out" ] || fail "auto refused a configured host for its GIT_CONFIG_GLOBAL: $out"
# Signing turned off against config.local, for both keys, while the key is
# also stale: ONE line, the override first (it names every key and file).
printf '[user]\n\tname = Jane Doe\n\temail = me@example.com\n\tsigningkey = key::%s\n[commit]\n\tgpgsign = true\n[tag]\n\tgpgsign = true\n' "$K1" > "$local_cfg"
printf '[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n' > "$HOME/.gitconfig"
printf 'me@example.com valid-before="20000101" %s\n' "$K1" > "$signers"
rc=0; out="$(bash -c 'set -euo pipefail; . "$1"; do_identity --mode auto --report-stale' _ "$installer" 2>&1)" || rc=$?
expect_rc 1 "auto --report-stale, both keys overridden and a stale key"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "more than one line for an override and a stale key: $out"
has "identity: signing is off against $local_cfg: commit.gpgsign = false from file:$HOME/.gitconfig; tag.gpgsign = false from file:$HOME/.gitconfig - see $installer identity" "the joined override line"
lacks "is not valid for" "the override line takes precedence over the stale one"
# The same host without a user.name: ONE line, and it is the name line, ahead
# of the override and the stale key (git refuses every commit without it).
git config --file "$local_cfg" --unset user.name
rc=0; out="$(bash -c 'set -euo pipefail; . "$1"; do_identity --mode auto --report-stale' _ "$installer" 2>&1)" || rc=$?
expect_rc 0 "auto --report-stale, overridden, stale and no user.name"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "the name line beside an override and a stale key: want one line: $out"
has "identity: user.name is not set - run: $installer identity --name \"" "the name line wins over the override line"
lacks "signing is off against" "the name line wins over the override line"
named
printf '[tag]\n\tgpgsign = false\n' > "$HOME/.gitconfig"
rc=0; out="$(bash -c 'set -euo pipefail; . "$1"; do_identity --mode auto --report-stale' _ "$installer" 2>&1)" || rc=$?
has "signing is off against $local_cfg: tag.gpgsign = false from file:$HOME/.gitconfig - see" "a tag.gpgsign override alone"
rm -f "$HOME/.gitconfig"
ok

# --- commits_fail_closed() says "every commit fails" only when git does ------
# A host with no user.signingkey still commits when git has another way to a
# key (gpg.ssh.defaultKeyCommand), signs with a format other than ssh, or
# cannot read commit.gpgsign at all (git then dies on the bad boolean, which
# the advisory and doctor name by its own line). None of these gets the
# fail-closed words from the automatic step, the advisory or doctor.
for shape in keycmd format typo; do
  fresh
  rm -f "$signers"
  case "$shape" in
    keycmd) printf '[gpg "ssh"]\n\tdefaultKeyCommand = ssh-add -L\n' > "$local_cfg" ;;
    format) printf '[gpg]\n\tformat = openpgp\n' > "$local_cfg" ;;
    typo) printf '[commit]\n\tgpgsign = flase\n' > "$local_cfg" ;;
  esac
  idrun
  expect_rc 1 "auto, $shape, no trust root"
  lacks "every commit fails" "auto does not say every commit fails ($shape)"
  rc=0; out="$(python3 -I -B "$module" --config-local "$local_cfg" --installer "$installer" --mode check 2>&1)" || rc=$?
  expect_rc 0 "check, $shape"
  lacks "user.signingkey is not set, so git refuses every commit" "the advisory does not say every commit fails ($shape)"
  rc=0; out="$(cd "$HOME" && "$installer" doctor 2>&1)" || rc=$?
  expect_rc 1 "doctor, $shape"
  lacks "user.signingkey is not set, so git refuses every commit" "doctor does not say every commit fails ($shape)"
  if [ "$shape" = typo ]; then
    has "doctor: values: commit.gpgsign is not a boolean git reads" "doctor names the unreadable commit.gpgsign"
  fi
done
# The same in an SSH session: the line keeps its plain "to set it on
# purpose" form when commits do not fail closed, for a host with a key but
# no email, one whose false comes from ~/.gitconfig (the exception), and one
# whose commit.gpgsign cannot be read.
for shape in keyed exception typo; do
  fresh
  printf 'me@example.com %s\n' "$K1" > "$signers"
  case "$shape" in
    keyed) printf '[user]\n\tsigningkey = key::%s\n' "$K1" > "$local_cfg" ;;
    exception) printf '[commit]\n\tgpgsign = false\n' > "$HOME/.gitconfig" ;;
    typo) printf '[commit]\n\tgpgsign = flase\n' > "$local_cfg" ;;
  esac
  rc=0; out="$(SSH_CONNECTION='10.0.0.1 22 10.0.0.2 22' bash -c 'set -euo pipefail; . "$1"; do_identity --mode auto' _ "$installer" 2>&1)" || rc=$?
  expect_rc 1 "auto in an SSH session, $shape"
  [ "$(grep -c . <<<"$out")" -eq 1 ] || fail "auto over SSH printed more than one line ($shape): $out"
  has "identity: not set automatically in an SSH session (a forwarded agent holds another machine's keys) - run $installer identity to set it on purpose" \
    "auto over SSH keeps the plain line when commits do not fail closed ($shape)"
  lacks "every commit fails" "auto over SSH does not say every commit fails ($shape)"
  rm -f "$HOME/.gitconfig"
done
ok

# --- .bak of an empty config.local --------------------------------------------
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
: > "$local_cfg"
run; expect_rc 0 "an empty config.local"
[ -f "$local_cfg.bak" ] && [ ! -s "$local_cfg.bak" ] || fail "the .bak of an empty config.local is not an empty file"
ok

# --- python3 unusable: warn and skip -----------------------------------------
fresh
mkdir -p "$work/nopy"
for t in git dirname bash; do ln -s "$(command -v "$t")" "$work/nopy/$t"; done
printf '#!/bin/sh\nexit 1\n' > "$work/nopy/python3"; chmod u+x "$work/nopy/python3"
rc=0; out="$(PATH="$work/nopy" "$installer" identity 2>&1)" || rc=$?
expect_rc 1 "python3 unusable"
has "identity: python3 is not usable here - skipping (install the Command Line Tools, then run $installer identity)" "python3 unusable names the full installer path"
# A checkout path is untrusted text and the line names it in a command: a
# path holding a quote, an ESC, a newline, a Latin-1 byte and UTF-8 prints as
# one $'...' word, every byte outside printable ASCII as \xNN, and that word
# pasted into a shell names the real path. The \351 byte exercises
# _shell_word's 255 mask only on the macOS legs, where install.sh runs under
# /bin/bash 3.2 (a negative "'c" there); bash 4 and later read it as 233 with
# or without the mask. The directory is made, not symlinked: install.sh
# resolves its own with pwd -P.
escdir="$work/co'$(printf '\033')[2J\\x$(printf '\n\351\303\251')"
mkdir -p "$escdir"
ln -s "$repo_root/install.sh" "$escdir/install.sh"
ln -s "$repo_root/lib" "$escdir/lib"
rc=0; out="$(PATH="$work/nopy" "$escdir/install.sh" identity 2>&1)" || rc=$?
expect_rc 1 "python3 unusable, quoted checkout path"
has "then run \$'$work/co\\'\\x1b[2J\\\\x\\x0a\\xe9\\xc3\\xa9/install.sh' identity)" "python3 unusable quotes the checkout path as one word"
raw_free() {
  local LC_ALL=C b
  for b in "$(printf '\033')" "$(printf '\351')" "$(printf '\303')"; do
    case $out in *"$b"*) fail "$1: output holds a raw byte (output: $out)" ;; esac
  done
  case $out in *"
"*) fail "$1: output holds a raw newline (output: $out)" ;; esac
}
raw_free "python3 unusable"
word="${out#*then run }"; word="${word% identity)}"
[ "$(eval "printf '%s' $word")" = "$escdir/install.sh" ] || fail "the printed word does not name the real installer: $word"
ok

# --- install.sh _shell_word: the shapes, and LC_ALL kept ----------------------
fresh
sw() { bash -c '. "$1"; _shell_word "$2"' _ "$installer" "$1"; }
for pair in "/a/b-c_d.e@f%g+h=i:j,k|/a/b-c_d.e@f%g+h=i:j,k" "|''" "\\|'\\'" "a b|'a b'" "it's|'it'\\''s'" \
  "$(printf 'n\nl')|\$'n\\x0al'" "$(printf 'd\177')|\$'d\\x7f'" "$(printf 'q\047\033')|\$'q\\'\\x1b'"; do
  want="${pair##*|}"; got="$(sw "${pair%|*}")"
  [ "$got" = "$want" ] || fail "_shell_word: [$got], want [$want]"
done
bash -c '. "$1"; unset LC_ALL; _shell_word "$(printf "\351")" >/dev/null; [ -z "${LC_ALL+x}" ]' _ "$installer" \
  || fail "_shell_word leaked its LC_ALL=C into the caller"
# Under a UTF-8 caller locale the helper still works on bytes: without its
# own LC_ALL=C, ${s:i:1} would take e-acute as one character and spell it
# \xe9 (its code point), not its two UTF-8 bytes.
utf8="$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.utf-?8$' | sed -n 1p)" || utf8=""
if [ -n "$utf8" ]; then
  got="$(LC_ALL="$utf8" bash -c '. "$1"; _shell_word "$2"' _ "$installer" "$(printf 'x\303\251')")"
  [ "$got" = "\$'x\\xc3\\xa9'" ] || fail "_shell_word under $utf8: [$got], want [\$'x\\xc3\\xa9']"
else
  echo "SKIP: _shell_word under a UTF-8 locale (locale -a lists no C.UTF-8 or en_US.UTF-8)"
fi
ok

# --- a config.local that is not a regular file: refused before any git read ---
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
mkfifo "$local_cfg"
start="$(date +%s)"
run
expect_rc 1 "a FIFO config.local"; has "$local_cfg is not a regular file - writing nothing" "a FIFO config.local"
idrun
expect_rc 1 "auto, a FIFO config.local"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "auto with a FIFO config.local printed more than one line: $out"
for gc in none present; do
  [ "$gc" = present ] && printf '[alias]\n\tst = status\n' > "$HOME/.gitconfig"
  bounded_run 20 "$work/advise.out" bash -c 'set -euo pipefail; . "$1"; _signing_advisory' _ "$installer" \
    || fail "bounded_run could not start (no job control)"
  [ "$br_hung" -eq 0 ] && [ "$br_stuck" -eq 0 ] || fail "the advisory hung on a FIFO config.local (~/.gitconfig: $gc)"
  [ "$br_rc" -eq 0 ] || fail "the advisory with a FIFO config.local exited $br_rc (~/.gitconfig: $gc)"
  [ ! -s "$work/advise.out" ] || fail "the advisory with a FIFO config.local printed: $(cat "$work/advise.out")"
done
rm -f "$HOME/.gitconfig"
[ $(( $(date +%s) - start )) -lt 20 ] || fail "a FIFO config.local stalled the step"
[ -p "$local_cfg" ] || fail "the FIFO config.local was replaced"
ok

# --- a principal holding a byte that is not UTF-8 is never written ------------
fresh
export FAKE_AGENT_KEYS="$K1"
printf 'a\377b@x.com %s\n' "$K1" > "$signers"
run
expect_rc 1 "a principal that is not UTF-8"; has "no ssh-agent key is listed for the git namespace" "non-UTF-8 principal"
unwritten "a principal that is not UTF-8"
ok

# --- a malformed line that names an agent key is an ambiguity ----------------
# A seconds field of 61 is malformed here and on macOS, but glibc's
# ssh-keygen reads it as valid: K2 may then be a second key for the email.
fresh
export FAKE_AGENT_KEYS="$K1
$K2"
printf 'me@example.com valid-before="20991231235961" %s\nme@example.com %s\n' "$K2" "$K1" > "$signers"
run
expect_rc 1 "a malformed line naming an agent key"
has "identity: malformed allowed-signers line(s) 1 in $signers name an ssh-agent key - writing nothing" "the ambiguity is named"
unwritten "a malformed line naming an agent key"
idrun
expect_rc 1 "auto, a malformed line naming an agent key"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "auto printed more than one line: $out"
# The key may hide where only a C reader finds it: before a NUL (ssh-keygen
# stops reading the line there, on every platform), glued to a quote, or
# with a form feed inside its base64 (b64_pton() skips it). The first four
# lines below verify K2 for ssh-keygen on glibc, the first three on every
# platform (tests/fixtures/allowed_signers/verify-git.txt holds their UNCLEAR
# vectors). ssh-keygen refuses the last one, whose key is quoted ("missing
# key"); the word-by-word reading still finds K2 in it, so the step writes
# nothing.
export FAKE_AGENT_KEYS="$K1
$K2"
k2_type="${K2%% *}"; k2_b64="${K2#* }"
for hidden in "me@example.com $K2\\0" "me@example.com $K2\\0junk" "\"me@example.com\"$K2\\0" \
  "me@example.com valid-before=\"20991231235961\" $k2_type ${k2_b64:0:20}\\f${k2_b64:20}" \
  "me@example.com \"$K2\""; do
  # shellcheck disable=SC2059  # the line is the format, so \0 and \f expand
  printf "$hidden\\nme@example.com %s\\n" "$K1" > "$signers"
  run
  expect_rc 1 "a malformed line hiding an agent key [$hidden]"
  has "identity: malformed allowed-signers line(s) 1 in $signers name an ssh-agent key - writing nothing" "hidden key [$hidden]"
  unwritten "a malformed line hiding an agent key [$hidden]"
done
# A malformed line naming no agent key changes nothing.
printf 'me@example.com valid-before="20991231235961" %s\nme@example.com %s\n' "$K3" "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
run
expect_rc 0 "a malformed line naming no agent key"
[ "$(get user.signingkey)" = "key::$K1" ] || fail "a malformed line elsewhere blocked the write"
# --rotate refuses on the same ambiguity: to glibc's ssh-keygen K2 is a second
# valid key for the email beside K3, so moving to K3 would be a guess.
fresh
printf '[user]\n\temail = me@example.com\n\tsigningkey = key::%s\n' "$K1" > "$local_cfg"
printf 'me@example.com valid-before="20991231235961" %s\nme@example.com valid-before="20000101" %s\nme@example.com %s\n' \
  "$K2" "$K1" "$K3" > "$signers"
export FAKE_AGENT_KEYS="$K1
$K2
$K3"
run --rotate
expect_rc 1 "--rotate beside a malformed line naming an agent key"
has "identity: malformed allowed-signers line(s) 1 in $signers name an ssh-agent key - writing nothing" "--rotate names the ambiguity"
[ "$(get user.signingkey)" = "key::$K1" ] || fail "--rotate wrote beside a malformed line: $(get user.signingkey)"
ok

# --- every listed agent key revoked, or the KRL unreadable: the cause is named --
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
printf '%s\n' "$K1" > "$HOME/revoked"
git config --file "$XDG_CONFIG_HOME/git/config" gpg.ssh.revocationFile '~/revoked'
run
expect_rc 1 "the only agent key revoked"
has "identity: every ssh-agent key listed in $signers is revoked by gpg.ssh.revocationFile $HOME/revoked - writing nothing" "revocation named"
lacks "no ssh-agent key is listed" "a revoked key is not called unlisted"
printf 'SSHKRL\n\0garbage' > "$HOME/revoked"
run
expect_rc 1 "an unreadable KRL"
has "identity: ssh-keygen -Q could not check the ssh-agent key(s) listed in $signers against gpg.ssh.revocationFile $HOME/revoked - writing nothing" "unreadable KRL named"
unwritten "a revoked or unchecked key"
# user.email set, its only key revoked, another email's key fine: the
# revocation is named, not "no key is listed for user.email".
printf 'me@example.com %s\nother@example.com %s\n' "$K1" "$K2" > "$signers"
printf '%s\n' "$K1" > "$HOME/revoked"
printf '[user]\n\temail = me@example.com\n' > "$local_cfg"
export FAKE_AGENT_KEYS="$K1
$K2"
run
expect_rc 1 "user.email whose key is revoked"
has "identity: every ssh-agent key listed for me@example.com in $signers is revoked by gpg.ssh.revocationFile $HOME/revoked - writing nothing" "revocation named for user.email, scoped to it"
lacks "listed in $signers is revoked" "the user.email case makes no claim about other emails' keys"
lacks "no ssh-agent key is listed for user.email" "a revoked key is not called unlisted for user.email"
ok

# --- a value that a later level overrides AFTER the write is reported ---------
# A git shim adds a command-line user.signingkey to every effective read once
# config.local holds one, so the real effective, --show-origin and read-back
# code runs against it, through install.sh.
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
mkdir -p "$work/shim"
real_git="$(command -v git)"
cat > "$work/shim/git" <<EOF
#!/bin/sh
case " \$* " in
  *" --includes "*) if grep -q signingkey "$local_cfg" 2>/dev/null; then
      exec "$real_git" -c "user.signingkey=key::$K2" "\$@"; fi ;;
esac
exec "$real_git" "\$@"
EOF
chmod u+x "$work/shim/git"
rc=0; out="$(PATH="$work/shim:$PATH" "$installer" identity 2>&1)" || rc=$?
expect_rc 1 "a signingkey overridden after the write"
has "identity: user.signingkey reads 'key::$K2' from command line: after the write, not the value written" "the override is named"
ok

# --- a signingkey this step cannot read is "not checked", never "will fail" ---
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
mkdir -p "$HOME/.ssh"
# A placeholder, not a key. The word is passed as an argument so the
# secret scanners never see a private-key header in this file.
printf -- '-----BEGIN OPENSSH %s KEY-----\nx\n-----END OPENSSH %s KEY-----\n' \
  PRIVATE PRIVATE > "$HOME/.ssh/id_sign"
printf '[user]\n\temail = me@example.com\n\tsigningkey = ~/.ssh/id_sign\n[commit]\n\tgpgsign = true\n' > "$local_cfg"
advise
expect_rc 0 "advisory, a private key without its .pub"
has "user.signingkey (~/.ssh/id_sign) is a certificate or a private key without its .pub - not checked" "not checked"
lacks "signing will fail" "a private key path is not called a failure"
# A signingkey value with a control character is printed escaped, never raw.
printf '[user]\n\temail = me@example.com\n[commit]\n\tgpgsign = true\n' > "$local_cfg"
git config --file "$local_cfg" user.signingkey "$(printf '~/.ssh/x\033[2J')"
advise
has "user.signingkey ('~/.ssh/x\\x1b[2J') names no readable SSH public key" "the advisory escapes a control character"
! grep -q "$(printf '\033')" <<<"$out" || fail "the advisory printed a raw escape byte: $out"
# A ~/.gitconfig key name with control bytes (ESC and BEL in a subsection) is
# printed escaped and quoted by the advisory too, as doctor prints it.
printf '[user "\033]0;PWNED\007"]\n\tx = 1\n' > "$HOME/.gitconfig"
rc=0; out="$(python3 -I -B "$module" --config-local "$local_cfg" --installer "$installer" --mode check 2>&1)" || rc=$?
expect_rc 0 "advisory, a ~/.gitconfig key with control bytes"
has "~/.gitconfig sets 'user.\\x1b]0;PWNED\\x07.x', and git reads it after" "the advisory escapes a ~/.gitconfig key name"
! grep -q "$(printf '\033')" <<<"$out" || fail "the advisory printed a raw ESC from ~/.gitconfig: $out"
! grep -q "$(printf '\007')" <<<"$out" || fail "the advisory printed a raw BEL from ~/.gitconfig: $out"
rm -f "$HOME/.gitconfig"
ok

# --- install.sh doctor: read only, silent when healthy, one line a problem ---
# snap - every path under $HOME with its inode, size, mode, mtime (in ns)
# and content hash, so a write, a touch, a rename or a new file shows as a
# difference. A symlink is recorded, never followed.
snap() {
  python3 -I -B -c '
import hashlib, os, sys
def line(p):
    st = os.lstat(p)
    h = ""
    if os.path.isfile(p) and not os.path.islink(p):
        with open(p, "rb") as f:
            h = hashlib.sha256(f.read()).hexdigest()
    print(p, st.st_ino, st.st_size, st.st_mode, st.st_mtime_ns, h)
line(sys.argv[1])
for root, dirs, files in os.walk(sys.argv[1]):
    dirs.sort()
    for n in sorted(dirs + files):
        line(os.path.join(root, n))
' "$HOME"
}
doc() { rc=0; out="$("$installer" doctor "$@" 2>&1)" || rc=$?; }
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
run --name "Jane Doe"; expect_rc 0 "doctor setup"
snap_before="$(snap)"
doc; expect_rc 0 "doctor on a healthy host"
[ -z "$out" ] || fail "doctor is not silent on a healthy host: $out"
doc --verbose; expect_rc 0 "doctor --verbose on a healthy host"
has "doctor: values: user.email = me@example.com (file:$local_cfg)" "doctor --verbose names a value and its origin"
has "doctor: values: gpg.format = ssh (file:$tracked_cfg)" "doctor --verbose names gpg.format's origin"
has "doctor: values: gpg.ssh.revocationFile is unset" "doctor --verbose names an unset value"
has "doctor: trust root: $signers (from gpg.ssh.allowedSignersFile): 1 entry" "doctor --verbose names the trust root and its source"
has "doctor: ssh-agent: $FP1 is listed for me@example.com in $signers" "doctor --verbose names the agent key match"
has "doctor: signing key: $FP1 verifies for me@example.com in $signers, loaded in the ssh-agent" "doctor --verbose verifies the key"
has "doctor: ssh-keygen:" "doctor --verbose checks ssh-keygen"
has "doctor: git: an [include] reaches $local_cfg" "doctor --verbose checks the include chain"
has "doctor: verdict: nothing needs action" "doctor --verbose verdict"
lacks "PRIVATE" "doctor never prints private material"
[ "$(snap)" = "$snap_before" ] || fail "doctor wrote under HOME (healthy host)"
# An SSH session is reported, never a problem.
rc=0; out="$(SSH_CONNECTION='10.0.0.1 22 10.0.0.2 22' "$installer" doctor --verbose 2>&1)" || rc=$?
expect_rc 0 "doctor in an SSH session"; has "doctor: ssh session: note: SSH_CONNECTION is set" "doctor names the SSH session"
# A stale key: one line, the cause and the fix.
printf 'me@example.com valid-before="20000101" %s\n' "$K1" > "$signers"
doc; expect_rc 1 "doctor, stale key"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "doctor printed more than one line for a stale key: $out"
has "doctor: signing key: user.signingkey $FP1 is not valid for me@example.com in $signers (line 1: expired) - new signatures will not verify; run: $installer identity --rotate" "doctor names the stale key and the fix"
printf 'me@example.com %s\n' "$K1" > "$signers"
# The configured key is not in the agent.
FAKE_AGENT_KEYS="$K2"
doc; expect_rc 1 "doctor, key not in the agent"
has "doctor: signing key: user.signingkey $FP1 is not loaded in the ssh-agent - signing will fail - ssh-add this host's signing key" "doctor names an unloaded key"
FAKE_AGENT_DOWN=1 doc; expect_rc 1 "doctor, agent down"
has "doctor: ssh-agent: cannot reach an ssh-agent (ssh-add -L exited 2) - load this host's signing key with ssh-add" "doctor names an unreachable agent"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "doctor printed more than one line for an unreachable agent: $out"
export FAKE_AGENT_KEYS="$K1"
# An override: config.local true (a copy an earlier release wrote; the step
# no longer writes it beside the tracked true), a later ~/.gitconfig false.
git config --file "$local_cfg" commit.gpgsign true
printf '[commit]\n\tgpgsign = false\n' > "$HOME/.gitconfig"
snap_gc="$(snap)"
doc; expect_rc 1 "doctor, override"
has "doctor: values: commit.gpgsign is true in $local_cfg, but file:$HOME/.gitconfig sets it false and wins - remove the false there, or the true in $local_cfg" "doctor names the override"
has "doctor: ~/.gitconfig: ~/.gitconfig sets commit.gpgsign, and git reads it after ~/.config/git/config - move its settings into $local_cfg and remove it" "doctor names the legacy ~/.gitconfig"
lacks "respected as this host's opt-out" "an override is not the opt-out"
[ "$(snap)" = "$snap_gc" ] || fail "doctor wrote under HOME (override)"
rm -f "$HOME/.gitconfig"
git config --file "$local_cfg" --unset commit.gpgsign
ln -s "$HOME/no-such-gitconfig" "$HOME/.gitconfig"
doc; expect_rc 1 "doctor, dangling ~/.gitconfig"
has "doctor: ~/.gitconfig: a dangling ~/.gitconfig symlink is in place, and its target's settings would override ~/.config/git/config - remove it" "doctor names a dangling ~/.gitconfig"
rm -f "$HOME/.gitconfig"
# An ssh-keygen that does not know -Y (OpenSSH before 8.2 answers this way).
mkdir -p "$work/oldkeygen"
printf '#!/bin/sh\necho "ssh-keygen: unknown option -- Y" >&2\necho "usage: ssh-keygen [-q]" >&2\nexit 1\n' > "$work/oldkeygen/ssh-keygen"
chmod u+x "$work/oldkeygen/ssh-keygen"
snap_before="$(snap)"
rc=0; out="$(PATH="$work/oldkeygen:$PATH" "$installer" doctor 2>&1)" || rc=$?
expect_rc 1 "doctor, ssh-keygen without -Y"
has "doctor: ssh-keygen: $work/oldkeygen/ssh-keygen does not support -Y, which git signs and verifies with - install OpenSSH 8.2 or later" "doctor names an ssh-keygen without -Y"
[ "$(snap)" = "$snap_before" ] || fail "doctor wrote under HOME"
# No trust root at all.
mv "$local_cfg" "$work/doc_local"
printf '[user]\n\tname = Jane Doe\n\temail = me@example.com\n\tsigningkey = key::%s\n[commit]\n\tgpgsign = true\n' "$K1" > "$local_cfg"
rm -f "$signers"
doc; expect_rc 1 "doctor, no trust root"
has "doctor: trust root: no allowed-signers file found - see docs/signing-key.md" "doctor names the missing trust root"
has "doctor: values: gpg.ssh.allowedSignersFile is not set, so git cannot verify signatures - run: $installer identity" "doctor names the unset allowedSignersFile"
# The include chain does not reach config.local.
printf '[gpg]\n\tformat = ssh\n' > "$XDG_CONFIG_HOME/git/config"
doc; expect_rc 1 "doctor, no include"
has "doctor: git: no [include] reaches $local_cfg, so git never reads it - see \"Framework git settings do not apply\" in docs/troubleshooting.md" "doctor names the missing include"
# A config.local that is not a regular file is named before any git read.
rm -f "$local_cfg"; mkfifo "$local_cfg"
bounded_run 20 "$work/doctor.out" "$installer" doctor || fail "bounded_run could not start (no job control)"
[ "$br_hung" -eq 0 ] && [ "$br_stuck" -eq 0 ] || fail "doctor hung on a FIFO config.local"
rc="$br_rc"; out="$(cat "$work/doctor.out")"
expect_rc 1 "doctor, FIFO config.local"
has "doctor: git: $local_cfg is not a regular file" "doctor names a FIFO config.local"
rm -f "$local_cfg"
# Usage, and a python3 that does not run.
doc --bogus; expect_rc 2 "doctor --bogus"; has "doctor: unknown option: --bogus (expected: --verbose)" "doctor usage"
doc --verbose --verbose; expect_rc 2 "doctor --verbose twice"
rc=0; out="$(PATH="$work/nopy" "$installer" doctor 2>&1)" || rc=$?
expect_rc 1 "doctor, python3 unusable"
has "doctor: python3: python3 -I -c '' does not run here - install the Command Line Tools (xcode-select --install)" "doctor names an unusable python3"
rc=0; out="$(python3 -I "$module" --config-local "$local_cfg" --mode check --verbose 2>&1)" || rc=$?
expect_rc 2 "--verbose outside --mode doctor"
rc=0; out="$("$installer" --help 2>&1)" || rc=$?
expect_rc 0 "--help"; has "|doctor [--verbose]]" "the usage line names doctor and --verbose"
ok

# --- doctor: each finding, and what an opt-out does and does not hide -------
# dhealthy - a fresh host that signs, with its name set: doctor is silent.
dhealthy() {
  fresh
  printf 'me@example.com %s\n' "$K1" > "$signers"
  export FAKE_AGENT_KEYS="$K1"
  run --name "Jane Doe"; expect_rc 0 "doctor setup"
  doc; expect_rc 0 "doctor setup is healthy"; [ -z "$out" ] || fail "doctor setup is not healthy: $out"
}
# one LABEL - exactly one line of output.
one() { [ "$(grep -c . <<<"$out")" -eq 1 ] || fail "$1: want one line, got: $out"; }
# An opted-out host still needs a name and an email: every commit carries
# them, signed or not. Signing problems (no agent, no key, no
# allowedSignersFile) stay notes there.
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
printf '[user]\n\temail = me@example.com\n[commit]\n\tgpgsign = false\n' > "$local_cfg"
FAKE_AGENT_DOWN=1 doc; expect_rc 1 "doctor, opted out, no user.name"; one "doctor, opted out, no user.name"
has "doctor: values: user.name is not set, so git refuses every commit - run: git config --file $local_cfg user.name \"Full Name\"" "an opted-out host still needs user.name"
printf '[user]\n\tname = Jane Doe\n[commit]\n\tgpgsign = false\n' > "$local_cfg"
FAKE_AGENT_DOWN=1 doc; expect_rc 1 "doctor, opted out, no user.email"; one "doctor, opted out, no user.email"
has "doctor: values: user.email is not set, so git refuses every commit - run: git config --file $local_cfg user.email <your email>" "an opted-out host still needs user.email"
printf '[user]\n\tname = Jane Doe\n\temail = me@example.com\n[commit]\n\tgpgsign = false\n' > "$local_cfg"
FAKE_AGENT_DOWN=1 doc; expect_rc 0 "doctor, opted out, name and email set"; [ -z "$out" ] || fail "doctor, opted out: $out"
FAKE_AGENT_DOWN=1 doc --verbose; expect_rc 0 "doctor --verbose, opted out"
has "doctor: ssh-agent: note: cannot reach an ssh-agent" "an opted-out host's agent is a note"
has "doctor: values: note: gpg.ssh.allowedSignersFile is not set" "an opted-out host's trust root setting is a note"
printf '[user]\n\temail = old@corp.example\n' > "$HOME/.gitconfig"
FAKE_AGENT_DOWN=1 doc; expect_rc 1 "doctor, opted out, ~/.gitconfig email"; one "doctor, opted out, ~/.gitconfig email"
has "doctor: ~/.gitconfig: ~/.gitconfig sets user.email, and git reads it after ~/.config/git/config" "an opted-out host still hears about ~/.gitconfig"
rm -f "$HOME/.gitconfig"
# The include chain broken: config.local is not read, so the host is not
# opted out, and the missing include is a problem.
printf '[gpg]\n\tformat = ssh\n' > "$XDG_CONFIG_HOME/git/config"
FAKE_AGENT_DOWN=1 doc; expect_rc 1 "doctor, opted out, include broken"
has "doctor: git: no [include] reaches $local_cfg" "a broken include on an opted-out host"
# user.useConfigOnly: the tracked true makes a missing name or email a
# refusal of every commit, and doctor says so; a false is the operator's
# escape, named as a note with its origin and never a problem; a value git
# cannot read as a boolean is a problem, since git then dies on most
# commands.
dhealthy
git config --file "$local_cfg" --unset user.name
doc; expect_rc 1 "doctor, no user.name"; one "doctor, no user.name"
has "doctor: values: user.name is not set, so git refuses every commit - run: $installer identity --name \"Full Name\"" "doctor says a missing user.name refuses every commit under useConfigOnly"
git config --file "$local_cfg" user.useConfigOnly false
doc; expect_rc 1 "doctor, no user.name, useConfigOnly false"; one "doctor, no user.name, useConfigOnly false"
has "doctor: values: user.name is not set - run: $installer identity --name \"Full Name\"" "a missing user.name without useConfigOnly is not called a refusal"
lacks "refuses every commit" "a missing user.name without useConfigOnly is not called a refusal"
git config --file "$local_cfg" user.name "Jane Doe"
doc; expect_rc 0 "doctor, useConfigOnly false"; [ -z "$out" ] || fail "a useConfigOnly false is a doctor note, not a problem: $out"
doc --verbose; expect_rc 0 "doctor --verbose, useConfigOnly false"
has "doctor: values: note: user.useConfigOnly = false from file:$local_cfg: git invents a name and an email from this account and host when none is set" "a useConfigOnly false is a doctor note, not a problem"
has "doctor: values: user.useConfigOnly = false (file:$local_cfg)" "doctor --verbose lists user.useConfigOnly with its origin"
git config --file "$local_cfg" user.useConfigOnly maybe
doc; expect_rc 1 "doctor, unparseable useConfigOnly"
has "doctor: values: user.useConfigOnly is not a boolean git reads (" "doctor names an unparseable user.useConfigOnly"
has "- git refuses to run most commands until it is; fix it in the file git -C ~ config --show-origin --get user.useConfigOnly names" "doctor names an unparseable user.useConfigOnly"
# Every spelling git reads as a boolean: yes, on and 1 keep the refusal;
# no, off and 0 are the note.
git config --file "$local_cfg" --unset user.name
for b in yes on 1; do
  git config --file "$local_cfg" user.useConfigOnly "$b"
  doc; expect_rc 1 "doctor, no user.name, useConfigOnly $b"; one "doctor, no user.name, useConfigOnly $b"
  has "doctor: values: user.name is not set, so git refuses every commit - run:" "useConfigOnly $b is a refusal"
done
for b in no off 0; do
  git config --file "$local_cfg" user.useConfigOnly "$b"
  doc --verbose; expect_rc 1 "doctor --verbose, no user.name, useConfigOnly $b"
  has "doctor: values: user.name is not set - run:" "useConfigOnly $b is not a refusal"
  lacks "refuses every commit" "useConfigOnly $b is not a refusal"
  has "doctor: values: note: user.useConfigOnly = false from file:$local_cfg:" "useConfigOnly $b is the note"
done
# user.useConfigOnly unset everywhere (a host that does not read the tracked
# true): no refusal and no note.
sed '/useConfigOnly/d' "$tracked_cfg" > "$work/tracked_no_only"
printf '[include]\n\tpath = %s\n[include]\n\tpath = config.local\n' "$work/tracked_no_only" > "$XDG_CONFIG_HOME/git/config"
git config --file "$local_cfg" --unset user.useConfigOnly
doc --verbose; expect_rc 1 "doctor --verbose, no user.name, useConfigOnly unset"
has "doctor: values: user.name is not set - run:" "useConfigOnly unset is not a refusal"
lacks "refuses every commit" "useConfigOnly unset is not a refusal"
has "doctor: values: user.useConfigOnly is unset" "doctor --verbose lists an unset user.useConfigOnly"
lacks "note: user.useConfigOnly" "useConfigOnly unset is not the note"
# A keyed host, not opted out, with no user.email: the identity step's line.
dhealthy
git config --file "$local_cfg" --unset user.email
doc; expect_rc 1 "doctor, no user.email"
has "doctor: values: user.email is not set, so git refuses every commit - run: $installer identity" "doctor says a missing user.email refuses every commit under useConfigOnly"
# tag.gpgsign = true keeps the signing checks: tags still sign.
dhealthy
git config --file "$local_cfg" commit.gpgsign false
printf 'me@example.com valid-before="20000101" %s\n' "$K1" > "$signers"
doc; expect_rc 1 "doctor, commit false and tag true, stale key"; one "doctor, commit false and tag true, stale key"
has "doctor: signing key: user.signingkey $FP1 is not valid for me@example.com" "a true tag.gpgsign keeps the stale-key problem"
doc --verbose
has "doctor: values: note: commit.gpgsign = false from file:$local_cfg, but tag.gpgsign is true: tags are signed, so the signing checks apply" "doctor says why a false with a true tag.gpgsign is not an opt-out"
has "doctor: verdict: 1 problem(s) need action" "the verbose verdict counts the problems"
idrun_stale() { rc=0; out="$(bash -c 'set -euo pipefail; . "$1"; do_identity --mode auto --report-stale' _ "$installer" 2>&1)" || rc=$?; }
idrun_stale; expect_rc 1 "link's step, commit false and tag true, stale key"
has "identity: user.signingkey $FP1 is not valid for me@example.com" "link names the stale key while tags sign"
# A system-level false is read before the tracked true and loses: commits
# stay signed, and there is nothing to report.
dhealthy
printf '[commit]\n\tgpgsign = false\n' > "$HOME/sys"
rc=0; out="$(GIT_CONFIG_SYSTEM="$HOME/sys" "$installer" doctor 2>&1)" || rc=$?
expect_rc 0 "doctor, a system false under the tracked true"; [ -z "$out" ] || fail "doctor, a system false: $out"
rm -f "$HOME/sys"
# A false outside config.local is not an opt-out: one problem, naming its
# file, for a false from ~/.gitconfig and from a file a plain [include] pulls
# in (both read after the tracked true); ~/.gitconfig is a problem of its own
# beside it.
for level in gitconfig include; do
  dhealthy
  case "$level" in
    gitconfig) file="$HOME/.gitconfig" ;;
    include) file="$HOME/included"
      printf '[include]\n\tpath = %s\n' "$file" >> "$XDG_CONFIG_HOME/git/config" ;;
  esac
  printf '[commit]\n\tgpgsign = false\n' > "$file"
  doc; expect_rc 1 "doctor, a false from $level"
  [ "$level" = gitconfig ] || one "doctor, a false from $level"
  has "doctor: values: commit.gpgsign = false from file:$file, outside $local_cfg, so commits are not signed - remove it there to sign, or set the false in $local_cfg to opt out" "doctor names a false from $level"
  lacks "opt-out;" "a false from $level is not the opt-out"
  rm -f "$file"
done
# A false in config.local that a later ~/.gitconfig false repeats: git reads
# the last one from outside config.local, so it is not the opt-out.
dhealthy
git config --file "$local_cfg" commit.gpgsign false
printf '[commit]\n\tgpgsign = false\n' > "$HOME/.gitconfig"
doc; expect_rc 1 "doctor, config.local false repeated in ~/.gitconfig"
has "doctor: values: commit.gpgsign = false from file:$HOME/.gitconfig, outside $local_cfg" "doctor names the later false outside config.local"
lacks "opt-out;" "a later false from ~/.gitconfig is not the opt-out"
rm -f "$HOME/.gitconfig"
git config --file "$local_cfg" --unset commit.gpgsign
# commit.gpgsign unset: the tracked config, which sets it, is not included.
cat "$XDG_CONFIG_HOME/git/config" > "$work/xdg_linked"
printf '[gpg]\n\tformat = ssh\n[include]\n\tpath = config.local\n' > "$XDG_CONFIG_HOME/git/config"
doc; expect_rc 1 "doctor, commit.gpgsign unset"; one "doctor, commit.gpgsign unset"
has "doctor: values: commit.gpgsign is not set, so git does not read the framework git config and commits are not signed - see \"Framework git settings do not apply\" in docs/troubleshooting.md" "doctor says an unset commit.gpgsign means the tracked config is not included"
cat "$work/xdg_linked" > "$XDG_CONFIG_HOME/git/config"
# A value git cannot read as a boolean fails every commit (or tag).
git config --file "$local_cfg" commit.gpgsign flase
doc; expect_rc 1 "doctor, commit.gpgsign = flase"; one "doctor, commit.gpgsign = flase"
has "doctor: values: commit.gpgsign is not a boolean git reads (" "doctor names an unparseable commit.gpgsign"
has "git refuses to commit until it is" "doctor says what an unparseable commit.gpgsign does"
git config --file "$local_cfg" commit.gpgsign true
git config --file "$local_cfg" tag.gpgsign flase
doc; expect_rc 1 "doctor, tag.gpgsign = flase"; one "doctor, tag.gpgsign = flase"
has "doctor: values: tag.gpgsign is not a boolean git reads (" "doctor names an unparseable tag.gpgsign"
git config --file "$local_cfg" tag.gpgsign true
# Command-line config and includeIf never reach doctor's reads: a false
# there is neither an opt-out nor an override.
rc=0; out="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_PARAMETERS="'commit.gpgsign'='false'" "$installer" doctor 2>&1)" || rc=$?
expect_rc 0 "doctor ignores command-line config"; [ -z "$out" ] || fail "doctor read command-line config: $out"
printf '[commit]\n\tgpgsign = false\n' > "$HOME/cond"
printf '[includeIf "onbranch:main"]\n\tpath = %s\n' "$HOME/cond" >> "$XDG_CONFIG_HOME/git/config"
doc; expect_rc 0 "doctor ignores includeIf"; [ -z "$out" ] || fail "doctor read an includeIf: $out"
# A git too old to sign with SSH keys.
mkdir -p "$work/oldgit"
printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version 2.30.1"; exit 0; fi\nexec "%s" "$@"\n' "$(command -v git)" > "$work/oldgit/git"
chmod u+x "$work/oldgit/git"
rc=0; out="$(PATH="$work/oldgit:$PATH" "$installer" doctor 2>&1)" || rc=$?
expect_rc 1 "doctor, git 2.30"; one "doctor, git 2.30"
has "doctor: git: git version 2.30.1 cannot sign with SSH keys (2.34 or later can) - upgrade git" "doctor names a git too old to sign"
# GIT_CONFIG_GLOBAL away from the XDG config.
rc=0; out="$(GIT_CONFIG_GLOBAL=/dev/null "$installer" doctor 2>&1)" || rc=$?
expect_rc 1 "doctor, GIT_CONFIG_GLOBAL=/dev/null"
has "doctor: git: GIT_CONFIG_GLOBAL=/dev/null is not $XDG_CONFIG_HOME/git/config, so git does not read $local_cfg - unset it" "doctor names GIT_CONFIG_GLOBAL"
# No ssh-keygen on PATH: only what install.sh and the checks call.
mkdir -p "$work/nokeygen"
for t in git dirname bash python3; do ln -sf "$(command -v "$t")" "$work/nokeygen/$t"; done
ln -sf "$work/fakebin/ssh-add" "$work/nokeygen/ssh-add"
rc=0; out="$(PATH="$work/nokeygen" "$installer" doctor 2>&1)" || rc=$?
expect_rc 1 "doctor, no ssh-keygen"
has "doctor: ssh-keygen: ssh-keygen was not found on PATH - git signs and verifies with it; install OpenSSH" "doctor names a missing ssh-keygen"
# An ssh-keygen that cannot be executed.
mkdir -p "$work/badkeygen"
printf '#!/nonexistent/interpreter\n' > "$work/badkeygen/ssh-keygen"; chmod u+x "$work/badkeygen/ssh-keygen"
rc=0; out="$(PATH="$work/badkeygen:$PATH" "$installer" doctor 2>&1)" || rc=$?
expect_rc 1 "doctor, ssh-keygen does not run"
has "doctor: ssh-keygen: ssh-keygen did not run (" "doctor names an ssh-keygen that does not run"
# gpg.format other than ssh.
git config --file "$local_cfg" gpg.format openpgp
doc; expect_rc 1 "doctor, gpg.format openpgp"
has "doctor: values: gpg.format is 'openpgp', not ssh" "doctor names gpg.format"
git config --file "$local_cfg" --unset gpg.format
# A malformed allowed-signers line that names an agent key.
export FAKE_AGENT_KEYS="$K1
$K2"
printf 'me@example.com valid-before="20991231235961" %s\nme@example.com %s\n' "$K2" "$K1" > "$signers"
doc; expect_rc 1 "doctor, an unclear allowed-signers line"
has "doctor: ssh-agent: malformed allowed-signers line(s) 1 in $signers name an ssh-agent key - fix or remove them" "doctor names an unclear line"
export FAKE_AGENT_KEYS="$K1"
printf 'me@example.com %s\n' "$K1" > "$signers"
# A signing key that is a private key file signs without the agent; doctor
# names it by fingerprint and never prints the file.
mkdir -p "$HOME/.ssh"
printf -- '-----BEGIN OPENSSH %s KEY-----\nx\n-----END OPENSSH %s KEY-----\n' PRIVATE PRIVATE > "$HOME/.ssh/id_sign"
printf '%s me\n' "$K1" > "$HOME/.ssh/id_sign.pub"
git config --file "$local_cfg" user.signingkey "~/.ssh/id_sign"
FAKE_AGENT_DOWN=1 doc; expect_rc 0 "doctor, a private key file and no agent"; [ -z "$out" ] || fail "doctor, private key file: $out"
FAKE_AGENT_DOWN=1 doc --verbose
has "doctor: signing key: $FP1 verifies for me@example.com in $signers, signs from its private key file" "doctor names a private key file signer"
lacks "BEGIN" "doctor never prints a private key file"
git config --file "$local_cfg" user.signingkey "key::$K1"
# A binary KRL: ssh-keygen -Q reads a temporary .pub, which is removed.
printf '%s\n' "$K2" > "$work/revoke.pub"
ssh-keygen -q -k -f "$HOME/krl" "$work/revoke.pub"
git config --file "$local_cfg" gpg.ssh.revocationFile "$HOME/krl"
mkdir -p "$work/tmpdir"
rc=0; out="$(TMPDIR="$work/tmpdir" "$installer" doctor --verbose 2>&1)" || rc=$?
expect_rc 0 "doctor, a binary KRL"
has "doctor: trust root: gpg.ssh.revocationFile $HOME/krl is readable" "doctor reads a binary KRL"
[ -z "$(ls -A "$work/tmpdir")" ] || fail "doctor left files in TMPDIR: $(ls -A "$work/tmpdir")"
# A value with a control character is printed escaped, never raw.
git config --file "$local_cfg" user.name "$(printf 'Jane\033[2JDoe')"
doc --verbose
has "Jane\\x1b[2JDoe" "doctor escapes a control character"
! grep -q "$(printf '\033')" <<<"$out" || fail "doctor printed a raw escape byte: $out"
ok

# --- --rotate and identity on an opted-out host -------------------------------
fresh
printf 'me@example.com valid-before="20000101" %s\nme@example.com %s\n' "$K1" "$K2" > "$signers"
export FAKE_AGENT_KEYS="$K2"
printf '[user]\n\temail = me@example.com\n\tsigningkey = key::%s\n[commit]\n\tgpgsign = false\n' "$K1" > "$local_cfg"
run --rotate
expect_rc 0 "--rotate on an opted-out host"
[ "$(get user.signingkey)" = "key::$K2" ] || fail "--rotate on an opted-out host: $(get user.signingkey)"
[ "$(get commit.gpgsign)" = false ] && [ "$(get tag.gpgsign)" = UNSET ] || fail "--rotate on an opted-out host touched signing"
ok

# --- the scratch-agent guard: an agent on any other socket aborts ------------
# A stub ssh-agent announces a live decoy socket and a live decoy PID, as an
# agent started elsewhere would, and the caller's environment already points
# at that decoy. The guard must refuse it by the socket path alone, leave the
# decoy process and socket alone, and never adopt the PID. The guard runs in
# a subshell (it exits on failure), so an EXIT trap there reports what it
# left in agent_pid and in the two agent variables.
stubdir="$(mktemp -d /tmp/hids.XXXXXX)"
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$stubdir/decoy.sock"
sleep 300 &
decoy_pid=$!
mkdir "$stubdir/bin" "$stubdir/s" "$stubdir/t"
printf '#!/bin/sh\necho "SSH_AUTH_SOCK=%s; export SSH_AUTH_SOCK;"\necho "SSH_AGENT_PID=%s; export SSH_AGENT_PID;"\n' \
  "$stubdir/decoy.sock" "$decoy_pid" > "$stubdir/bin/ssh-agent"
chmod u+x "$stubdir/bin/ssh-agent"
# guarded DIR - start_scratch_agent DIR with the decoy inherited; sets out, rc.
guarded() {
  rc=0
  out="$(PATH="$stubdir/bin:$PATH"
    export SSH_AUTH_SOCK="$stubdir/decoy.sock" SSH_AGENT_PID="$decoy_pid"
    trap 'echo "left: agent_pid=[$agent_pid] sock=[${SSH_AUTH_SOCK:-}] pid=[${SSH_AGENT_PID:-}]"' EXIT
    start_scratch_agent "$1" 2>&1)" || rc=$?
}
guarded "$stubdir/s"
expect_rc 1 "the guard refuses an agent on another socket"
has "is not on $stubdir/s/a" "the guard names the socket it wanted"
has "left: agent_pid=[] " "the guard never adopts the announced PID"
kill -0 "$decoy_pid" 2>/dev/null || fail "the guard touched the decoy agent's process"
[ -S "$stubdir/decoy.sock" ] || fail "the guard touched the decoy agent's socket"
[ -d "$work" ] || fail "the guard's failure ran the suite's cleanup"
# An agent that announces the right socket but no PID: the inherited
# SSH_AGENT_PID must not stand in for it (the guard unsets both first).
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$stubdir/t/a"
printf '#!/bin/sh\necho "SSH_AUTH_SOCK=%s; export SSH_AUTH_SOCK;"\n' "$stubdir/t/a" > "$stubdir/bin/ssh-agent"
guarded "$stubdir/t"
expect_rc 1 "the guard refuses an agent that names no PID"
has "the scratch ssh-agent on $stubdir/t/a did not come up" "no PID is a failed start"
has "left: agent_pid=[] sock=[$stubdir/t/a] pid=[]" "the inherited agent variables are dropped, never adopted"
# An agent that announces nothing: the inherited socket is not left in place.
printf '#!/bin/sh\nexit 0\n' > "$stubdir/bin/ssh-agent"
guarded "$stubdir/s"
expect_rc 1 "the guard refuses an agent that announces nothing"
has "left: agent_pid=[] sock=[] pid=[]" "a silent start leaves no inherited agent variable"
kill -0 "$decoy_pid" 2>/dev/null || fail "the guard touched the decoy agent's process"
kill "$decoy_pid" 2>/dev/null || :
wait "$decoy_pid" 2>/dev/null || :
decoy_pid=""
rm -rf "$stubdir"; stubdir=""
ok

# --- commit signing is mandatory where git reads the tracked config ---------
# The tracked config sets commit.gpgsign = true; fresh() includes it, then
# config.local, as the link engine does.
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
# a config.local false overrides the tracked true: git reads both, the
# tracked one first, and the last one wins.
printf '[commit]\n\tgpgsign = false\n' > "$local_cfg"
origins="$(git -C "$HOME" config --show-origin --get-all commit.gpgsign)"
[ "$origins" = "$(printf 'file:%s\ttrue\nfile:%s\tfalse' "$tracked_cfg" "$local_cfg")" ] \
  || fail "a config.local false overrides the tracked true: origins are [$origins]"
[ "$(git -C "$HOME" config --type=bool --get commit.gpgsign)" = false ] \
  || fail "a config.local false overrides the tracked true: the effective value is not false"
# identity on a linked host does not write commit.gpgsign: it is effectively
# true already, and a copy an earlier release wrote is left alone.
rm -f "$local_cfg"
run
expect_rc 0 "identity on a linked host"
[ "$(get commit.gpgsign)" = UNSET ] \
  || fail "identity on a linked host does not write commit.gpgsign: $(cat "$local_cfg")"
has "identity: wrote user.email, user.signingkey, tag.gpgsign, gpg.ssh.allowedSignersFile to $local_cfg" \
  "identity on a linked host does not write commit.gpgsign (its wrote line)"
git config --file "$local_cfg" commit.gpgsign true
before="$(ls -li "$local_cfg")"; content="$(cat "$local_cfg")"
run
expect_rc 0 "identity beside an earlier copy of commit.gpgsign"
has "identity: already configured for me@example.com ($FP1)" "an earlier copy of commit.gpgsign is equal, so nothing is written"
[ "$(ls -li "$local_cfg")" = "$before" ] && [ "$(cat "$local_cfg")" = "$content" ] \
  || fail "identity rewrote a config.local holding an earlier copy of commit.gpgsign"
ok

# a commit with no signing key fails closed: a real git commit, under the
# test HOME, with the tracked config and nothing else. No identity in config:
# the committer comes from the environment, which no signing setting reads.
fresh
git init -q "$HOME/repo"
echo x > "$HOME/repo/f"
git -C "$HOME/repo" add f
rc=0; out="$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x \
  git -C "$HOME/repo" commit -q -m unsigned 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a commit with no signing key fails closed: it succeeded"
has "either user.signingkey or gpg.ssh.defaultKeyCommand needs to be configured" "a commit with no signing key fails closed"
! git -C "$HOME/repo" rev-parse -q --verify HEAD >/dev/null || fail "a commit with no signing key fails closed: a commit was made"
# The same host opted out in config.local commits, unsigned.
printf '[commit]\n\tgpgsign = false\n' > "$local_cfg"
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x \
  git -C "$HOME/repo" commit -q -m unsigned || fail "an opted-out host cannot commit"
[ "$(git -C "$HOME/repo" cat-file commit HEAD | grep -c '^gpgsig' || :)" = 0 ] || fail "an opted-out host signed a commit"
ok

# the advisory and doctor say commits fail without a key, and how out.
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
advise
expect_rc 0 "the advisory with no key"
has "commit signing is on, but user.signingkey is not set, so git refuses every commit." "the advisory says commits fail without a key"
has "Run $installer identity on this host, or opt it out of signing" "the advisory says commits fail without a key (the way out)"
lacks "commit signing is NOT enabled" "the advisory does not call a fail-closed host unsigned"
doc
expect_rc 1 "doctor with no key"
has "doctor: values: user.signingkey is not set, so git refuses every commit - run: $installer identity, or opt this host out of signing (see docs/signing-key.md)" \
  "doctor says git refuses every commit without a key"
lacks "commit.gpgsign is not set" "doctor does not call the tracked commit.gpgsign unset"
ok

# --- end to end: a real agent, a real signed commit, a real verification ----
fresh
PATH="${PATH#"$work/fakebin:"}"
[ "$(command -v ssh-add)" = "$real_ssh_add" ] || fail "e2e: the fake ssh-add is still on PATH"
# A short socket path: sun_path is about 104 bytes on macOS, and a deep
# TMPDIR would not fit.
sockdir="$(mktemp -d /tmp/hid.XXXXXX)"
start_scratch_agent "$sockdir"
ssh-keygen -q -t ed25519 -N '' -C dotfiles-signing@e2e -f "$work/sign"
ssh-keygen -q -t ed25519 -N '' -C old-host -f "$work/old"
ssh-keygen -q -t ed25519 -N '' -C auth-only -f "$work/auth"
ssh-add -q "$work/sign" "$work/auth" 2>/dev/null
pub() { cut -d' ' -f1,2 "$1"; }
printf 'e2e@example.com namespaces="git" %s old\ne2e@example.com namespaces="git" %s new\n' \
  "$(pub "$work/old.pub")" "$(pub "$work/sign.pub")" > "$signers"
run --name "E2E Tester"
expect_rc 0 "e2e identity"
[ "$(get user.signingkey)" = "key::$(pub "$work/sign.pub")" ] || fail "e2e: picked $(get user.signingkey)"
want_fp="$(ssh-keygen -lf "$work/sign.pub" | awk '{ print $2 }')"
git init -q "$work/e2e_repo"
echo hi > "$work/e2e_repo/f"
git -C "$work/e2e_repo" add f
# No -S and no commit.gpgsign in config.local: with the key the step wrote,
# a commit is signed because the tracked config says so.
[ "$(get commit.gpgsign)" = UNSET ] || fail "e2e: the step wrote commit.gpgsign beside the tracked true"
[ "$(git -C "$HOME" config --show-origin --get commit.gpgsign)" = "$(printf 'file:%s	true' "$tracked_cfg")" ] \
  || fail "with the key the step wrote, a commit is signed: commit.gpgsign does not come from the tracked config"
git -C "$work/e2e_repo" commit -q -m signed || fail "with the key the step wrote, a commit is signed: the commit failed"
git -C "$work/e2e_repo" verify-commit HEAD 2>/dev/null || fail "e2e: verify-commit failed"
got="$(git -C "$work/e2e_repo" log -1 --format='%G?|%GS|%GF|%ae|%an')"
[ "$got" = "G|e2e@example.com|$want_fp|e2e@example.com|E2E Tester" ] \
  || fail "e2e: signature is [$got], want [G|e2e@example.com|$want_fp|e2e@example.com|E2E Tester]"
ok

[ -z "$(ls -A "$work/tmp")" ] || fail "runs left directories in TMPDIR: $(ls -A "$work/tmp")"
echo "PASS: host_identity_test ($pass groups)"
