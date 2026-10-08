#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for config/git/config + config.local.example. Verifies the tracked
# config's portable keys, that a relative `[include] path = config.local`
# resolves through the dir SYMLINK the link engine creates (~/.config/git ->
# repo/config/git), that no identity is baked into the tracked file, that the
# .example is well-formed, and that dotfiles-upgrade re-asserts fsckObjects even
# under its scrubbed config. Hermetic mktemp HOME; the real repo is never
# modified (a COPY of config/git is used for the symlink case). Not on the
# repo's shellcheck surface.
set -euo pipefail

# A privilege skip: install.sh refuses root for every subcommand, so nothing
# below can run as root (tests/root_refusal_test.sh covers that refusal).
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  echo "SKIP: git_config_test (running as root: install.sh refuses root)"
  exit 0
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ck() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail "$1: got [$2] want [$3]"; fi; }
if ! command -v git >/dev/null 2>&1; then
  if [ -n "${STRICT:-}" ]; then fail "git not installed and STRICT=1"; fi
  echo "SKIP: git unavailable"; exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/git_config_test.XXXXXX")"
# Everything happens under $work - the advisory is tested against a COPY of
# config/git with a scratch symlink, NEVER the real repo (on an installed host a
# real config.local lives in the repo via the ~/.config/git symlink; writing or
# deleting it there would destroy the user's identity + signing key).
trap 'rm -rf "$work"' EXIT INT TERM
export GIT_CONFIG_SYSTEM=/dev/null       # ignore the host's /etc/gitconfig

# Mirror the link engine: ~/.config/git is a dir SYMLINK to a COPY of the tracked
# config/git (a copy so the test never writes into the real repo). Run git from a
# NEUTRAL cwd so the dotfiles repo's own .git/config local scope can't leak in.
cp -R "$repo_root/config/git" "$work/gitdir"
# A `cp -R` on an INSTALLED host also copies the untracked, per-host config.local;
# the `[include] path = config.local` in the tracked config would then leak the
# host identity into the "no identity in tracked config" assertions below (a real
# FAIL on any installed host, invisible on a fresh CI checkout that has none).
# Drop it so the copy is tracked-only - the relative-include case further down
# plants its own config.local under $work/gitdir.
rm -f "$work/gitdir/config.local"
mkdir -p "$work/home/.config" "$work/neutral"
ln -s "$work/gitdir" "$work/home/.config/git"
gc() { HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" git -C "$work/neutral" config "$@"; }

# --- portable keys are present in the tracked config --------------------------
ck "transfer.fsckObjects true" "$(gc --get transfer.fsckObjects)" "true"
ck "fetch.fsckObjects true"    "$(gc --get fetch.fsckObjects)" "true"
ck "receive.fsckObjects true"  "$(gc --get receive.fsckObjects)" "true"
ck "gpg.format ssh"            "$(gc --get gpg.format)" "ssh"
ck "push.autoSetupRemote true"               "$(gc --get push.autoSetupRemote)" "true"
ck "init.defaultBranch main"                 "$(gc --get init.defaultBranch)" "main"
ck "pushf alias is force-with-lease"         "$(gc --get alias.pushf)" "push --force-with-lease"

# diff-so-fancy pager wiring - GUARDED so it degrades to plain less where the tool
# is absent, so `git diff` never breaks there.
ck "core.pager wires diff-so-fancy"          "$(gc --get core.pager | grep -c diff-so-fancy)" "1"
ck "core.pager degrades to less without it"  "$(gc --get core.pager | grep -cE '\|\| less')" "1"
ck "diffFilter wires diff-so-fancy"          "$(gc --get interactive.diffFilter | grep -c diff-so-fancy)" "1"

# --- NO identity or signing key baked into the tracked config -----------------
# user.* are per-host -> they must come only from config.local. Absent (get
# returns nonzero) = correct.
ck "no user.name in tracked config"  "$(gc --get user.name || echo UNSET)" "UNSET"
ck "no user.email in tracked config" "$(gc --get user.email || echo UNSET)" "UNSET"
ck "no signingkey in tracked config" "$(gc --get user.signingkey || echo UNSET)" "UNSET"
# Commit signing is mandatory in the tracked file itself; tags stay per host,
# written by the identity step. Read from the file alone, without includes, so
# only the tracked file can answer.
tracked="$repo_root/config/git/config"
ck "the tracked config sets commit.gpgsign true and not tag.gpgsign" \
  "$(git config --file "$tracked" --get commit.gpgsign):$(git config --file "$tracked" --get tag.gpgsign || echo UNSET)" \
  "true:UNSET"
for k in tag.forceSignAnnotated user.useConfigOnly; do
  ck "the tracked config leaves $k unset" "$(git config --file "$tracked" --get "$k" || echo UNSET)" "UNSET"
done
ck "the tracked config sets no gpg.ssh.* key" \
  "$(git config --file "$tracked" --get-regexp '^gpg\.ssh\.' || echo UNSET)" "UNSET"

# --- the RELATIVE include resolves through the symlink ------------------------
# Drop a config.local next to the config (in the copy the symlink points at) and
# confirm git picks it up via `[include] path = config.local` - the exact path a
# real install takes (~/.config/git is a symlink into the repo).
cat > "$work/gitdir/config.local" <<'EOF'
[user]
	name = Host Identity
	email = id@host
[commit]
	gpgsign = false
EOF
ck "relative include resolves via symlink (user.name)" "$(gc --get user.name)" "Host Identity"
ck "config.local can turn the tracked signing off"     "$(gc --get commit.gpgsign)" "false"
# and it OVERRIDES nothing it shouldn't - fsck still on
ck "config.local present, fsck still on"               "$(gc --get fetch.fsckObjects)" "true"
rm -f "$work/gitdir/config.local"

# --- config.local.example is well-formed and safe to ship ---------------------
# It must parse as git config, and must NOT hardcode a real identity/secret.
ex="$repo_root/config/git/config.local.example"
git config --file "$ex" --list >/dev/null 2>&1 || fail "config.local.example does not parse as git config"
# A copied example must not block `install.sh identity`: an ACTIVE placeholder
# is a value already set, which the step keeps and then writes nothing beside.
# So no identity or signing key is active, and the placeholders are comments.
for k in user.name user.email user.signingkey commit.gpgsign tag.gpgsign tag.forceSignAnnotated \
  gpg.ssh.allowedSignersFile gpg.ssh.revocationFile; do
  ck "example leaves $k unset" "$(git config --file "$ex" --get "$k" || echo UNSET)" "UNSET"
done
for want in 'name = Your Name' 'email = you@example.com' 'signingkey = ~/.ssh/id_signing.pub'; do
  grep -qE "^#[[:space:]]+$want\$" "$ex" || fail "example lacks the commented placeholder: $want"
done
pass=$((pass + 1))
if grep -qiE 'BEGIN [A-Z ]*PRIVATE KEY|(ssh-(ed25519|rsa)|ecdsa-sha2-[a-z0-9-]+|sk-ssh-ed25519@openssh.com) AAAA' "$ex"; then
  fail "config.local.example embeds real key material"
fi
# tag.forceSignAnnotated defeats `git tag --no-sign` and the opt-out, so the
# example does not suggest it, not even commented (git reads names in any case).
ck "the example never mentions tag.forceSignAnnotated" "$(grep -ci forcesignannotated "$ex" || :)" "0"
# Style-independent twin of the uncommenting below: whatever indentation a
# commented line takes, no line of the example may read as a gpgsign opt-out
# (false, no, off or 0), with or without the commit. prefix.
ck "the example carries no commented gpgsign opt-out line" \
  "$(grep -ciE '^#[[:space:]]*(commit\.)?gpgsign[[:space:]]*=[[:space:]]*(false|no|off|0)[[:space:]]*$' "$ex" || :)" "0"
# The example says to uncomment and edit each line: doing exactly that, with
# the result included after the tracked config the way the link engine writes
# ~/.config/git/config (lib/link.sh's _write_git_local_config), must leave
# commit signing on. An opt-out is a decision, never a line to uncomment.
# A commented config line is `# [section]` or `# <TAB>key = value`; awk's
# \t in a regex is POSIX and macOS awk reads it.
xdg="$work/xdg"; mkdir -p "$xdg/git" "$work/xhome"
awk '/^# \[/ || /^# \t/ { sub(/^# /, "") } { print }' "$ex" > "$xdg/git/config.local"
printf '[include]\n\tpath = %s\n[include]\n\tpath = config.local\n' "$work/gitdir/config" > "$xdg/git/config"
xgc() { HOME="$work/xhome" XDG_CONFIG_HOME="$xdg" git -C "$work/neutral" config "$@"; }
ck "the uncommented example is the identity it shows" "$(xgc --get user.email)" "you@example.com"
ck "uncommenting every line of the example keeps commit signing on" \
  "$(xgc --type=bool --get commit.gpgsign)" "true"

# --- dotfiles-upgrade re-asserts fsckObjects under its scrubbed config ---------
# Part 2: vgit scrubs GLOBAL/SYSTEM config, so it must pass fsckObjects
# via -c or the upgrade would fetch/merge with object fsck OFF.
for k in transfer.fsckObjects fetch.fsckObjects receive.fsckObjects; do
  grep -q -- "-c $k=true" "$repo_root/install.sh" \
    || fail "install.sh vgit does not re-assert $k (part 2)"
done
pass=$((pass + 1))

# --- the vgit fsck re-assertion actually OVERRIDES a hostile config
# The grep above only proves the -c string exists; prove the guarantee it stands
# for. Even if a global (or config.local) sets fetch.fsckObjects=false, the
# upgrade's fetch runs with it TRUE - because the -c wins, AND because vgit blanks
# GIT_CONFIG_GLOBAL so the hostile value never loads at all.
hostile="$work/hostile.gitconfig"
printf '[fetch]\n\tfsckObjects = false\n' > "$hostile"
ck "-c fetch.fsckObjects=true overrides a hostile global false" \
  "$(GIT_CONFIG_GLOBAL="$hostile" git -c fetch.fsckObjects=true config --get fetch.fsckObjects)" "true"
ck "scrubbed global (/dev/null) + -c yields fsck ON" \
  "$(GIT_CONFIG_GLOBAL=/dev/null git -c fetch.fsckObjects=true config --get fetch.fsckObjects)" "true"

# --- install-time signing advisory, ISOLATED via sourcing --------
# install.sh guards its dispatch, so sourcing it runs no install; call
# _signing_advisory directly against a scratch symlinked config (a COPY of
# config/git). It reads the EFFECTIVE commit.gpgsign (through
# lib/host_identity.py's advisory(), so python3 must run) and never writes into
# the real repo (where a host's real config.local - identity + signing key -
# lives).
adv="$work/adv"; mkdir -p "$adv/.config"
cp -R "$repo_root/config/git" "$adv/gitdir"
# Same as the copy above: on an installed host `cp -R` carries in the untracked,
# per-host config.local, which would make the "no config.local -> advisory FIRES"
# case below start dirty. Drop it - each case from here plants its own config.local.
rm -f "$adv/gitdir/config.local"
ln -s "$adv/gitdir" "$adv/.config/git"
# Never an agent of the caller's (a forwarded one holds another machine's
# keys): the advisory asks the agent about a configured key.
unset SSH_AUTH_SOCK SSH_AGENT_PID GIT_CONFIG_GLOBAL
# A throwaway public key (the same fixture as host_identity_test's K1).
K1='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE7ZriufNPIzaGKLCOFNHpr6/MYnrT97GT7G1THBmdJR'
run_advisory() {   # echoes the advisory's output (empty when silent)
  HOME="$adv" XDG_CONFIG_HOME="$adv/.config" \
    bash -c 'set -euo pipefail; . "$1/install.sh"; _signing_advisory' _ "$repo_root" 2>&1
}
# Match with a here-string, NOT `printf … | grep -q`: under `set -o pipefail`,
# grep -q closes the pipe on its first match, the printf takes SIGPIPE (exit 141),
# and pipefail propagates that as the pipeline status - so a firing advisory would
# intermittently read as "did not fire". A here-string has no upstream writer to
# signal, so the result is the grep's alone.
# no config.local -> the tracked commit.gpgsign = true with no key: git refuses
# every commit, so the advisory FIRES and names both ways out
out="$(run_advisory)"
grep -qF 'commit signing is on, but user.signingkey is not set, so git refuses every commit.' <<<"$out" \
  && pass=$((pass + 1)) || fail "the advisory says commits fail without a key: $out"
grep -qF 'install.sh identity on this host, or opt it out of signing' <<<"$out" \
  && pass=$((pass + 1)) || fail "the advisory names install.sh identity and the opt-out: $out"
# config.local with a signing key -> no refusal line (the key's own checks are
# host_identity_test's; no agent is reachable here, see above)
printf '[user]\n\tsigningkey = key::%s\n' "$K1" > "$adv/gitdir/config.local"
grep -qF 'git refuses every commit' <<<"$(run_advisory)" \
  && fail "the advisory says commits fail beside a signing key" || pass=$((pass + 1))
# config.local saying gpgsign=false -> SILENT: the host opted out of signing
# on purpose, and only config.local can say so
printf '[user]\n\tname = x\n[commit]\n\tgpgsign = false\n' > "$adv/gitdir/config.local"
[ -z "$(run_advisory)" ] || fail "advisory fired on a host that opted out in config.local"
pass=$((pass + 1))
# --type=bool: a falsy variant (no) opts out too, not a literal-string misread
printf '[commit]\n\tgpgsign = no\n' > "$adv/gitdir/config.local"
[ -z "$(run_advisory)" ] || fail "advisory misread commit.gpgsign=no (needs --type=bool)"
pass=$((pass + 1))
# ...while a false from any other level must STILL FIRE (effective value, not
# mere file existence): it may be nobody's decision for this host. From
# ~/.gitconfig, which git reads after the tracked true; a system-level false
# is read before it, and loses.
printf '[user]\n\tname = x\n' > "$adv/gitdir/config.local"
printf '[commit]\n\tgpgsign = false\n' > "$adv/.gitconfig"
grep -qF 'commit signing is NOT enabled on this host (commit.gpgsign is false).' <<<"$(run_advisory)" \
  && pass=$((pass + 1)) || fail "advisory did not fire with a ~/.gitconfig commit.gpgsign=false"
rm -f "$adv/.gitconfig"
# A system-level false is read before the tracked true and loses: commits
# stay signed, so the advisory still says a host with no key cannot commit,
# and never calls signing off.
printf '[user]\n\tname = x\n' > "$adv/gitdir/config.local"
printf '[commit]\n\tgpgsign = false\n' > "$adv/system.gitconfig"
out="$(GIT_CONFIG_SYSTEM="$adv/system.gitconfig" run_advisory)"
grep -qF 'commit signing is on, but user.signingkey is not set, so git refuses every commit.' <<<"$out" \
  && ! grep -qF 'commit signing is NOT enabled' <<<"$out" \
  && pass=$((pass + 1)) || fail "a system-level false must lose to the tracked true in the advisory: $out"
# config.local with identity but no key -> must STILL FIRE (fails closed)
printf '[user]\n\tname = x\n\temail = x@y\n' > "$adv/gitdir/config.local"
grep -qF 'git refuses every commit' <<<"$(run_advisory)" \
  && pass=$((pass + 1)) || fail "advisory did not fire with no key (identity-only config.local)"
# git does not read the tracked config -> commit.gpgsign unset: the advisory
# points at the include repair, not at the signing setup
printf '[user]\n\tname = x\n' > "$adv/plain.gitconfig"
out="$(GIT_CONFIG_GLOBAL="$adv/plain.gitconfig" run_advisory)"
grep -qF 'commit signing is NOT enabled on this host (commit.gpgsign is unset).' <<<"$out" \
  && grep -qF 'see "Framework git settings do not apply" in docs/troubleshooting.md.' <<<"$out" \
  && pass=$((pass + 1)) || fail "an unset commit.gpgsign must point at the include repair: $out"
# a residual ~/.gitconfig carrying signing settings warns (the XDG-only clash: a
# legacy GPG key vs the framework's gpg.format=ssh makes commits fail closed while
# gpgsign still reads true).
printf '[commit]\n\tgpgsign = true\n' > "$adv/gitdir/config.local"
printf '[user]\n\tsigningkey = ABCD1234DEADBEEF\n' > "$adv/.gitconfig"
grep -qF '~/.gitconfig sets user.signingkey' <<<"$(run_advisory)" \
  && pass=$((pass + 1)) || fail "advisory did not warn about a residual ~/.gitconfig with signing"
# an innocuous ~/.gitconfig (no identity or signing keys) is named, never as
# one that sets something
printf '[alias]\n\tst = status\n' > "$adv/.gitconfig"
grep -qF '~/.gitconfig sets' <<<"$(run_advisory)" \
  && fail "advisory warned about a signing-free ~/.gitconfig" || pass=$((pass + 1))
rm -f "$adv/.gitconfig"

echo "PASS: git_config_test ($pass assertions)"
