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

work="$(mktemp -d "${TMPDIR:-/tmp}/host_identity_test.XXXXXX")"
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
# ~/.config/git/config shaped like the one the link engine writes: gpg.format
# = ssh (the tracked config's) and an include of config.local, so effective
# reads see what a real host sees.
n=0
fresh() {
  n=$((n + 1))
  export HOME="$work/h$n" XDG_CONFIG_HOME="$work/h$n/.config"
  mkdir -p "$XDG_CONFIG_HOME/git"
  printf '[gpg]\n\tformat = ssh\n[include]\n\tpath = config.local\n' > "$XDG_CONFIG_HOME/git/config"
  signers="$XDG_CONFIG_HOME/git/allowed_signers"
  local_cfg="$XDG_CONFIG_HOME/git/config.local"
  : > "$signers"
}
get() { git config --file "$local_cfg" --get "$1" || echo UNSET; }
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
mkdir -p "$work/units"
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
[ "$(get commit.gpgsign)" = "true" ] || fail "happy path: commit.gpgsign"
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
has "a ~/.gitconfig exists: its values override" "present ~/.gitconfig"
rm -f "$HOME/.gitconfig"
ok

# --- auto mode: non-fatal, quiet once configured, never rotates --------------
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
idrun() { rc=0; out="$(bash -c 'set -euo pipefail; . "$1"; do_identity --mode auto' _ "$installer" 2>&1)" || rc=$?; }
idrun; expect_rc 0 "auto mode writes"
[ "$(get user.email)" = "me@example.com" ] || fail "auto mode did not write"
export FAKE_AGENT_DOWN=1
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
# host's exception, so link says so in one line, and still exits 0.
git config --file "$local_cfg" --unset gpg.ssh.revocationFile
before="$(ls -li "$local_cfg")"; content="$(cat "$local_cfg")"
printf '[commit]\n\tgpgsign = false\n' > "$HOME/.gitconfig"
rc=0; out="$(bash "$B/install.sh" link </dev/null 2>&1)" || rc=$?
expect_rc 0 "link with signing overridden off"
[ "$(grep -c 'identity:' <<<"$out")" -eq 1 ] || fail "link printed more than one identity line: $out"
has "identity: signing is off against $local_cfg: commit.gpgsign = false from file:$HOME/.gitconfig - see $B/install.sh identity" "link names the override"
[ "$(ls -li "$local_cfg")" = "$before" ] && [ "$(cat "$local_cfg")" = "$content" ] || fail "an override report rewrote config.local"
rm -f "$HOME/.gitconfig"
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
# still write nothing)
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
    other=commit.gpgsign; [ "$key" = commit.gpgsign ] && other=tag.gpgsign
    [ "$(get "$other")" = true ] || fail "$key = false in $where: $other not written"
    if [ "$where" = global ]; then [ "$(get "$key")" = UNSET ] || fail "$key written beside a global false"; fi
    # Quiet afterwards, through the automatic step too.
    idrun; expect_rc 0 "auto after $key = false in $where"; [ -z "$out" ] || fail "auto not quiet: $out"
  done
done
# The automatic step that writes beside an exception says so, after the write.
fresh
printf 'me@example.com %s\n' "$K1" > "$signers"
export FAKE_AGENT_KEYS="$K1"
printf '[commit]\n\tgpgsign = false\n' > "$HOME/.gitconfig"
idrun
expect_rc 0 "auto writes beside a false"
has "identity: wrote user.email" "auto writes beside a false"
has "identity: commit.gpgsign is false (file:$HOME/.gitconfig) - kept as this host's exception, so it stays off" "auto names the exception when it writes"
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
# The automatic step refuses in ONE line: the exception line is said only
# when the step goes on to write.
idrun
expect_rc 1 "auto, a false beside a key conflict"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "auto printed more than one line beside an exception: $out"
lacks "kept as this host's exception" "auto does not print the exception line when it refuses"
advise() { rc=0; out="$(bash -c 'set -euo pipefail; . "$1"; _signing_advisory' _ "$installer" 2>&1)" || rc=$?; }
printf '[commit]\n\tgpgsign = false\n' > "$HOME/.gitconfig"
advise
has "commit signing is NOT enabled on this host (commit.gpgsign is false)." "advisory names the actual value"
has "An explicit false is kept as this host's exception" "advisory names the exception"
has "a legacy ~/.gitconfig carries signing settings" "advisory warns about the ~/.gitconfig with signing off"
# An explicit false does not silence the stale-key report: a key can go
# stale while commit signing is off.
printf '[user]\n\temail = me@example.com\n\tsigningkey = key::%s\n[commit]\n\tgpgsign = false\n' "$K1" > "$local_cfg"
printf 'me@example.com valid-before="20000101" %s\n' "$K1" > "$signers"
advise
has "An explicit false is kept as this host's exception" "advisory names the exception"
has "user.signingkey $FP1 is not valid for me@example.com" "the stale key is reported beside an explicit false"
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
has "identity: no allowed-signers file found - writing nothing (details: $installer identity)" "auto one line"
printf 'me@example.com %s\n' "$K1" > "$signers"
rc=0; out="$(SSH_CONNECTION='10.0.0.1 22 10.0.0.2 22' bash -c 'set -euo pipefail; . "$1"; do_identity --mode auto' _ "$installer" 2>&1)" || rc=$?
expect_rc 1 "auto in an SSH session"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "auto over SSH printed more than one line: $out"
has "not set automatically in an SSH session" "SSH session hint"; has "$installer identity" "SSH hint names the installer"
unwritten "auto in an SSH session"
rc=0; out="$(SSH_CONNECTION='10.0.0.1 22 10.0.0.2 22' "$installer" identity 2>&1)" || rc=$?
expect_rc 0 "an explicit identity run in an SSH session"
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
printf '[user]\n\temail = me@example.com\n\tsigningkey = key::%s\n[commit]\n\tgpgsign = true\n' "$K1" > "$other_global"
rc=0; out="$(GIT_CONFIG_GLOBAL="$other_global" bash -c 'set -euo pipefail; . "$1"; do_identity --mode auto --report-stale' _ "$installer" 2>&1)" || rc=$?
expect_rc 0 "auto on a configured host under another GIT_CONFIG_GLOBAL"
[ -z "$out" ] || fail "auto refused a configured host for its GIT_CONFIG_GLOBAL: $out"
# Signing turned off against config.local, for both keys, while the key is
# also stale: ONE line, the override first (it names every key and file).
printf '[user]\n\temail = me@example.com\n\tsigningkey = key::%s\n[commit]\n\tgpgsign = true\n[tag]\n\tgpgsign = true\n' "$K1" > "$local_cfg"
printf '[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n' > "$HOME/.gitconfig"
printf 'me@example.com valid-before="20000101" %s\n' "$K1" > "$signers"
rc=0; out="$(bash -c 'set -euo pipefail; . "$1"; do_identity --mode auto --report-stale' _ "$installer" 2>&1)" || rc=$?
expect_rc 1 "auto --report-stale, both keys overridden and a stale key"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "more than one line for an override and a stale key: $out"
has "identity: signing is off against $local_cfg: commit.gpgsign = false from file:$HOME/.gitconfig; tag.gpgsign = false from file:$HOME/.gitconfig - see $installer identity" "the joined override line"
lacks "is not valid for" "the override line takes precedence over the stale one"
printf '[tag]\n\tgpgsign = false\n' > "$HOME/.gitconfig"
rc=0; out="$(bash -c 'set -euo pipefail; . "$1"; do_identity --mode auto --report-stale' _ "$installer" 2>&1)" || rc=$?
has "signing is off against $local_cfg: tag.gpgsign = false from file:$HOME/.gitconfig - see" "a tag.gpgsign override alone"
rm -f "$HOME/.gitconfig"
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
git -C "$work/e2e_repo" commit -q -m signed || fail "e2e: the signed commit failed"
git -C "$work/e2e_repo" verify-commit HEAD 2>/dev/null || fail "e2e: verify-commit failed"
got="$(git -C "$work/e2e_repo" log -1 --format='%G?|%GS|%GF|%ae|%an')"
[ "$got" = "G|e2e@example.com|$want_fp|e2e@example.com|E2E Tester" ] \
  || fail "e2e: signature is [$got], want [G|e2e@example.com|$want_fp|e2e@example.com|E2E Tester]"
ok

echo "PASS: host_identity_test ($pass groups)"
