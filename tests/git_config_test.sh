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
# user.*/commit.gpgsign are per-host -> they must come only from config.local, so a
# fresh clone with no key can still commit. Absent (get returns nonzero) = correct.
ck "no user.name in tracked config"  "$(gc --get user.name || echo UNSET)" "UNSET"
ck "no user.email in tracked config" "$(gc --get user.email || echo UNSET)" "UNSET"
ck "no signingkey in tracked config" "$(gc --get user.signingkey || echo UNSET)" "UNSET"
ck "no commit.gpgsign in tracked config" "$(gc --get commit.gpgsign || echo UNSET)" "UNSET"

# --- the RELATIVE include resolves through the symlink ------------------------
# Drop a config.local next to the config (in the copy the symlink points at) and
# confirm git picks it up via `[include] path = config.local` - the exact path a
# real install takes (~/.config/git is a symlink into the repo).
cat > "$work/gitdir/config.local" <<'EOF'
[user]
	name = Host Identity
	email = id@host
[commit]
	gpgsign = true
EOF
ck "relative include resolves via symlink (user.name)" "$(gc --get user.name)" "Host Identity"
ck "config.local can enable signing"                   "$(gc --get commit.gpgsign)" "true"
# and it OVERRIDES nothing it shouldn't - fsck still on
ck "config.local present, fsck still on"               "$(gc --get fetch.fsckObjects)" "true"
rm -f "$work/gitdir/config.local"

# --- config.local.example is well-formed and safe to ship ---------------------
# It must parse as git config, and must NOT hardcode a real identity/secret.
ex="$repo_root/config/git/config.local.example"
git config --file "$ex" --list >/dev/null 2>&1 || fail "config.local.example does not parse as git config"
ck "example uses a placeholder name"  "$(git config --file "$ex" --get user.name)"  "Your Name"
ck "example uses a placeholder email" "$(git config --file "$ex" --get user.email)" "you@example.com"
# signingkey must be a placeholder .pub PATH - never a real key or private material
exkey="$(git config --file "$ex" --get user.signingkey)"
case "$exkey" in *.pub) : ;; *) fail "example signingkey is not a placeholder .pub path: $exkey" ;; esac
if grep -qiE 'BEGIN [A-Z ]*PRIVATE KEY|(ssh-(ed25519|rsa)|ecdsa-sha2-[a-z0-9-]+|sk-ssh-ed25519@openssh.com) AAAA' "$ex"; then
  fail "config.local.example embeds real key material"
fi

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
# config/git). It reads the EFFECTIVE commit.gpgsign and never writes into the
# real repo (where a host's real config.local - identity + signing key - lives).
adv="$work/adv"; mkdir -p "$adv/.config"
cp -R "$repo_root/config/git" "$adv/gitdir"
# Same as the copy above: on an installed host `cp -R` carries in the untracked,
# per-host config.local, which would make the "no config.local -> advisory FIRES"
# case below start dirty. Drop it - each case from here plants its own config.local.
rm -f "$adv/gitdir/config.local"
ln -s "$adv/gitdir" "$adv/.config/git"
run_advisory() {   # echoes the advisory's output (empty when silent)
  HOME="$adv" XDG_CONFIG_HOME="$adv/.config" \
    bash -c 'set -euo pipefail; . "$1/install.sh"; _signing_advisory' _ "$repo_root" 2>&1
}
# Match with a here-string, NOT `printf … | grep -q`: under `set -o pipefail`,
# grep -q closes the pipe on its first match, the printf takes SIGPIPE (exit 141),
# and pipefail propagates that as the pipeline status - so a firing advisory would
# intermittently read as "did not fire". A here-string has no upstream writer to
# signal, so the result is the grep's alone.
# no config.local -> commit.gpgsign unset -> advisory FIRES
grep -qi 'commit signing is NOT enabled' <<<"$(run_advisory)" \
  && pass=$((pass + 1)) || fail "advisory did not fire with no config.local"
# …and it names WHERE to fix it (the untracked config.local), not a bare "enable it".
grep -q 'config/git/config.local' <<<"$(run_advisory)" \
  && pass=$((pass + 1)) || fail "advisory must point at ~/.config/git/config.local"
# config.local enabling gpgsign -> SILENT (tests the effective value + --includes)
printf '[commit]\n\tgpgsign = true\n' > "$adv/gitdir/config.local"
[ -z "$(run_advisory)" ] || fail "advisory fired despite commit.gpgsign=true"
pass=$((pass + 1))
# config.local present but gpgsign=false -> must STILL FIRE (effective value, not
# mere file existence) - the partial-config case the advisory exists to catch
printf '[user]\n\tname = x\n[commit]\n\tgpgsign = false\n' > "$adv/gitdir/config.local"
grep -qi 'commit signing is NOT enabled' <<<"$(run_advisory)" \
  && pass=$((pass + 1)) || fail "advisory did not fire with commit.gpgsign=false"
# config.local with identity but gpgsign UNSET -> must STILL FIRE
printf '[user]\n\tname = x\n\temail = x@y\n' > "$adv/gitdir/config.local"
grep -qi 'commit signing is NOT enabled' <<<"$(run_advisory)" \
  && pass=$((pass + 1)) || fail "advisory did not fire with gpgsign unset (identity-only config.local)"
# --type=bool: a truthy variant (yes) must be SILENT, not a literal-string misfire
printf '[commit]\n\tgpgsign = yes\n' > "$adv/gitdir/config.local"
[ -z "$(run_advisory)" ] || fail "advisory misfired on commit.gpgsign=yes (needs --type=bool)"
pass=$((pass + 1))
# a residual ~/.gitconfig carrying signing settings warns (the XDG-only clash: a
# legacy GPG key vs the framework's gpg.format=ssh makes commits fail closed while
# gpgsign still reads true). gpgsign=true keeps the first advisory silent.
printf '[commit]\n\tgpgsign = true\n' > "$adv/gitdir/config.local"
printf '[user]\n\tsigningkey = ABCD1234DEADBEEF\n' > "$adv/.gitconfig"
grep -qi 'legacy ~/.gitconfig' <<<"$(run_advisory)" \
  && pass=$((pass + 1)) || fail "advisory did not warn about a residual ~/.gitconfig with signing"
# an innocuous ~/.gitconfig (no signing keys) must NOT warn
printf '[alias]\n\tst = status\n' > "$adv/.gitconfig"
grep -qi 'legacy ~/.gitconfig' <<<"$(run_advisory)" \
  && fail "advisory warned about a signing-free ~/.gitconfig" || pass=$((pass + 1))
rm -f "$adv/.gitconfig"

echo "PASS: git_config_test ($pass assertions)"
