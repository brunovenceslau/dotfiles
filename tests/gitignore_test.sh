#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Tests for .gitignore's secret-hygiene rules: key and credential material
# (private keys, certificate bundles, env files), the machine-local `.local`
# layer and the real rclone/restic configs are ignored anywhere in the tree,
# while their documented `.example` templates stay committable. Also proves no
# TRACKED file matches an ignore rule, so a new pattern cannot silently hide a
# file the repo ships. `git check-ignore --no-index` evaluates the rules against
# paths that need not exist, so nothing is written to the tree.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0

if ! command -v git >/dev/null 2>&1; then
  if [ -n "${STRICT:-}" ]; then fail "git unavailable and STRICT=1"; fi
  echo "SKIP: gitignore_test (git unavailable)"; exit 0
fi

ignored() { git -C "$repo_root" check-ignore -q --no-index -- "$1"; }

for p in \
  server.pem certs/client.key bundle.p12 bundle.pfx \
  .env config/app/.env .env.production \
  id_rsa id_rsa.pub keys/id_ed25519 id_ecdsa \
  zsh/aliases.zsh.local packages/gh-extensions.local.txt \
  config/rclone/rclone.conf config/restic/photos_b2.env config/restic/password; do
  ignored "$p" || fail "not ignored, but must be: $p"
  pass=$((pass + 1))
done

for p in \
  .env.example certs/client.key.example \
  zsh/.zshrc.local.example config/git/config.local.example \
  config/rclone/README.md config/rclone/rclone.conf.example \
  config/restic/README.md config/restic/repo.env.example; do
  if ignored "$p"; then fail "ignored, but a template must stay committable: $p"; fi
  pass=$((pass + 1))
done

tracked="$(git -C "$repo_root" ls-files -ci --exclude-standard)"
[ -z "$tracked" ] || fail "tracked files match an ignore rule: $tracked"
pass=$((pass + 1))

echo "PASS: gitignore_test ($pass assertions)"
