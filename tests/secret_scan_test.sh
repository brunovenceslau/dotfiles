#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit tests for bin/secret-scan - the high-confidence
# secret scanner and its `make secret-scan` gate. Proves it CATCHES a planted
# secret (the negative fixture: a scanner that flags nothing would pass every
# other assertion vacuously), stays quiet on placeholders / public keys / prose,
# and that the real tracked tree scans clean. Hermetic: fixtures under a mktemp
# dir. Not part of the shellcheck surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
scan="$repo_root/bin/secret-scan"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0

[ -x "$scan" ] || fail "bin/secret-scan not found or not executable"

work="$(mktemp -d "${TMPDIR:-/tmp}/secret_scan_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# --- Every needle is ASSEMBLED at run time, never written as a literal --------
# The fixtures below must carry real secret SHAPES to exercise the scanner, and
# they build each one by juxtaposing two inert fragments, so the tracked tree
# contains no secret-shaped literal anywhere. The `secret-scan:allow` marker
# waives a line for this repository's own two scanners only (bin/secret-scan and
# `make gitleaks`); a third-party scanner and GitHub's push protection read the
# same bytes on the server and honour neither, and a literal that reaches the
# server costs a history rewrite to remove. Splitting the needle removes the
# finding at its source instead of waiving it once per scanner - measured: with
# the literals in place, `gitleaks dir .` under the default rule set flagged
# three lines of this file and nothing else in the tree.
#
# So: do NOT "simplify" a fragment pair back into one string, and do NOT reach
# for the marker to silence what that would reintroduce.
pem_begin='-----BEGIN OPENSSH PRIV''ATE KEY-----'
pem_end='-----END OPENSSH PRIV''ATE KEY-----'

# --- CATCHES a planted secret (the mandated negative fixture) -----------------
# A PEM/OpenSSH private-key block is the canonical unambiguous case: always a
# secret, never a placeholder. The scanner MUST flag it (exit 1) and name the file.
# The runtime fixture file holds the assembled block, which is what makes the
# scanner-under-test flag it (that is the assertion).
key="$work/id_leak"
printf '%s\n' "$pem_begin" > "$key"
printf 'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtz\n' >> "$key"
printf '%s\n' "$pem_end" >> "$key"
if out="$("$scan" "$key" 2>&1)"; then fail "scanner did NOT flag a planted private key"; fi
grep -q 'private-key-block' <<<"$out" || fail "planted key not labeled private-key-block: $out"
grep -q "$(basename "$key")" <<<"$out" || fail "scanner did not name the leaking file"
pass=$((pass + 2))

# A credential assignment with a real-looking value and a provider token are also
# caught; the AWS example key ID (a well-known 20-char AKIA) is caught by shape.
printf 'aws_secret_access_key = %s\n' '7c4a8d09ca3762af61e5''9520943dc26494f8941b' > "$work/creds"
"$scan" "$work/creds" >/dev/null 2>&1 && fail "real credential assignment not flagged"
printf 'access = %s\n' 'AKIA''IOSFODNN7EXAMPLE' > "$work/akia"
"$scan" "$work/akia" >/dev/null 2>&1 && fail "AWS access key id shape not flagged"
pass=$((pass + 2))

# Regression (path-heuristic tightening): a base64 secret whose VALUE merely starts
# with '/' and has a later '/' must NOT be excused as a path - the exclusion now
# requires a real path prefix (~/, ./, ../, an absolute /lowercase-word/ root, or a
# macOS root), not "any leading slash". Fixture value has no such prefix.
printf 'secret_access_key = %s\n' '/aB3cD4eF5gH6iJ7kL8mN''/9oPqRsT' > "$work/slashsecret"
"$scan" "$work/slashsecret" >/dev/null 2>&1 && fail "base64 secret starting with / wrongly excused as a path"
# Regression (value-anchored exclusion): a real secret sharing a line with a
# placeholder WORD in a trailing comment must still be caught - the placeholder
# exclusion is anchored to the value, so a space-separated `# EXAMPLE` can't reach it.
printf 'client_secret = %s # EXAMPLE deployment\n' 'a1B2c3D4e5F6g7H8i9J0''kLmNoPqRsT' > "$work/commentsecret"
"$scan" "$work/commentsecret" >/dev/null 2>&1 && fail "secret with a placeholder word in a trailing comment wrongly excused"
pass=$((pass + 2))

# --- QUIET on placeholders, public keys, and prose (zero false positives) -----
# Placeholder values, $VARs, and ~/paths - exactly the rclone/restic template
# shapes - must pass, or `make secret-scan` over A would be a false alarm.
cat > "$work/placeholders" <<'EOF'
secret_access_key = YOUR_SECRET_ACCESS_KEY
password = CHANGE_ME
api_key = $MY_TOKEN
RESTIC_PASSWORD_FILE = ~/.config/restic/password
signingkey = 491EFC82666C38B9
EOF
"$scan" "$work/placeholders" >/dev/null 2>&1 || fail "placeholders/paths/vars wrongly flagged (false positive)"
# A PUBLIC ssh key is NOT a secret.
printf 'principal@host ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabcdefghijklmnopqrstuvwxyz0123456789ABCD comment\n' \
  > "$work/pubkey"
"$scan" "$work/pubkey" >/dev/null 2>&1 || fail "a public ssh key was wrongly flagged as a secret"
# Prose full of the WORDS secret/token/password must not trip it.
printf 'The framework must never commit a secret, token, or password.\n' > "$work/prose"
"$scan" "$work/prose" >/dev/null 2>&1 || fail "prose mentioning secret/token/password wrongly flagged"
pass=$((pass + 3))

# --- git mode: --git scans the tracked files -----------------------------------
g="$work/repo"; mkdir -p "$g"
git init -q "$g"; git -C "$g" config user.email a@x; git -C "$g" config user.name a
# Hermetic signing: the scan is signature-agnostic, so pin commit.gpgsign off in
# the scratch repo - otherwise a developer/CI global `commit.gpgsign = true` makes
# this commit try to sign with a key that a non-interactive runner cannot unlock.
git -C "$g" config commit.gpgsign false
printf 'clean\n' > "$g/clean.txt"; git -C "$g" add clean.txt; git -C "$g" commit -q -m init
"$scan" --git "$g" >/dev/null 2>&1 || fail "--git flagged a clean tracked tree"
# A committed secret is caught by --git (the tracked tree is what the gate scans).
cp "$key" "$g/id_leak"; git -C "$g" add id_leak; git -C "$g" commit -q -m leak
"$scan" --git "$g" >/dev/null 2>&1 && fail "--git did not catch a committed secret"
# The withdrawn --staged mode (2026-09-13) must be refused as an unknown option, never
# silently accepted as a no-op scan.
srct=0; "$scan" --staged "$g" >/dev/null 2>&1 || srct=$?
[ "$srct" = 2 ] || fail "--staged must be refused as an unknown option (exit 2), got $srct"
pass=$((pass + 3))

# --- The allowlist marker exempts a line carrying a secret shape --------------
# The per-line waiver, proven in both directions: this same BEGIN line is flagged
# in the id_leak fixture above and is NOT flagged here, and the only difference
# is the marker. No fixture in this file relies on it (they assemble their
# needles instead), so the mechanism would rot unmeasured without this case.
printf '%s  ok secret-scan:allow\n' "$pem_begin" > "$work/marked"
"$scan" "$work/marked" >/dev/null 2>&1 || fail "secret-scan:allow marker did not exempt its line"
pass=$((pass + 1))

# --- The real tracked tree scans clean ----------------------------------------
"$scan" --git "$repo_root" >/dev/null 2>&1 || fail "the real tracked tree has secret-shaped content"
pass=$((pass + 1))

# --- Makefile wiring: a target that IS a local-ci prerequisite ----------------
mk="$repo_root/Makefile"
grep -Eq '^secret-scan:' "$mk" || fail "Makefile has no 'secret-scan' target"
grep -q 'bin/secret-scan' "$mk" || fail "secret-scan target must call bin/secret-scan"
if ! grep -qw secret-scan <<<"$(grep -E '^local-ci:' "$mk")"; then
  fail "secret-scan must be a local-ci prerequisite"
fi
pass=$((pass + 3))

echo "PASS: secret_scan_test ($pass assertions)"
