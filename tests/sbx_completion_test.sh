#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# sbx's zsh completion (sbx is the Docker Sandboxes CLI, Docker, Inc.): a thin
# wrapper over the contract tests/lib/cached_completion.sh proves once for
# both canga and sbx. See that file for what PART 1 (generation) and PART 2
# (loading) each cover.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/cached_completion.sh
. "$repo_root/tests/lib/cached_completion.sh"

run_cached_completion_suite sbx
