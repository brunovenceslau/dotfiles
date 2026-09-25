#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Doc drift tests, modelled on tests/restic_wrappers_test.sh's usage-line
# cross-check against the code that actually prints it:
#
#   (a) every subcommand arm in install.sh's dispatch `case` is named in its
#       own header usage block, and the reverse - the header cannot name a
#       subcommand that has no arm. `reseed-settings`, the one retired no-op
#       arm this repo ships today, is handled explicitly: it must still be
#       named somewhere in the header, just not in the primary bulleted
#       usage list (see CLAUDE.md, ## Never, "Delete a subcommand from
#       install.sh").
#   (b) the bin/ tool count docs/architecture.md's Exceptions section states
#       in prose matches how many `bin/...` entries the table row it
#       introduces actually lists.
#
# Each check is proven capable of failing: it runs first against a mutated
# SCRATCH copy (built with awk/sed into $work, the tracked file is never
# touched) with the drift planted, then against the real tracked file.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
install="$repo_root/install.sh"
arch_doc="$repo_root/docs/architecture.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ok: $1"; }
# A literal backtick, held in a variable so every pattern that matches
# docs/architecture.md's `bin/...` markdown can use double-quoted "${bt}..."
# interpolation instead of an unexpanded backtick sitting inside single
# quotes, which shellcheck SC2016 flags on every such pattern.
bt='`'

work="$(mktemp -d "${TMPDIR:-/tmp}/subcommand_docs_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# --- shared helpers --------------------------------------------------------

# contains LIST ITEM - true if ITEM is one of LIST's newline-separated lines.
# A read loop, not a pipe into grep -q: it always drains LIST fully, so it
# never races a concurrent writer under pipefail (see .claude/rules/shell-bash.md,
# "Never pipe into a reader that exits early").
contains() {
  local list="$1" item="$2" x
  while IFS= read -r x; do
    [ "$x" = "$item" ] && return 0
  done <<EOF
$list
EOF
  return 1
}

# case_arm_names FILE - install.sh's dispatch case arm names, one per line;
# "*" dropped, pipe-separated alternatives ("-h | --help | help") split out.
case_arm_names() {
  awk '/^case "\$cmd" in$/{p=1; next} /^esac$/{if(p) exit} p' "$1" \
    | grep -E '^  [^ ].*\)$' \
    | sed -E 's/^  //; s/\)$//' \
    | tr '|' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -v '^\*$'
}

# header_usage_names FILE - the subcommand names install.sh's own header
# "install.sh <name> ..." usage lines name. A bracketed flag ([--purge]) is
# an argument, not a name, and is dropped; a bracketed bare word ([install])
# marks the default subcommand and is kept. Relies on the 2+ space gap
# before each description, which install.sh's own header comment documents
# as load-bearing for exactly this reason.
header_usage_names() {
  grep -E '^#   install\.sh ' "$1" \
    | sed -E 's/^#   install\.sh //; s/  +.*$//' \
    | sed -E 's/\[--[a-zA-Z0-9_-]+\]//g' \
    | tr -d '[]' \
    | tr '|' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -v '^$'
}

# header_block FILE - install.sh's comment header, everything above the
# `set -euo pipefail` line.
header_block() {
  awk '/^set -euo pipefail$/{exit} {print}' "$1"
}

# check_subcommand_docs FILE - prints nothing and returns 0 when the case
# arms and the header usage names agree. reseed-settings is excepted from
# the primary bulleted list (and must NOT appear there - it is asserted
# absent, not merely un-asserted), but is required somewhere in the wider
# header block; otherwise prints the mismatch and returns 1.
check_subcommand_docs() {
  local f="$1" case_names header_names block name missing="" extra="" rc=0
  case_names="$(case_arm_names "$f")"
  header_names="$(header_usage_names "$f")"
  block="$(header_block "$f")"

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$name" = "reseed-settings" ] && continue   # checked separately, below
    contains "$header_names" "$name" || missing="$missing $name"
  done <<EOF
$case_names
EOF

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    contains "$case_names" "$name" || extra="$extra $name"
  done <<EOF
$header_names
EOF

  if [ -n "$missing" ]; then echo "case arm(s) missing from the header usage block:$missing"; rc=1; fi
  if [ -n "$extra" ]; then echo "header names a subcommand with no case arm:$extra"; rc=1; fi
  if contains "$header_names" "reseed-settings"; then
    echo "the retired 'reseed-settings' arm is in the primary bulleted usage list - it belongs only in the retired-arm note"
    rc=1
  fi
  case "$block" in
    *reseed-settings*) : ;;
    *) echo "the retired 'reseed-settings' arm is not named anywhere in the header block"; rc=1 ;;
  esac
  return "$rc"
}

# word_to_num WORD - a small English number word to digit, "one".."ten".
# Anything else (a future doc typo, or a number spelled some other way)
# returns -1, which never equals a real count and so always fails loudly
# instead of silently passing.
word_to_num() {
  case "$1" in
    one) echo 1 ;; two) echo 2 ;; three) echo 3 ;; four) echo 4 ;; five) echo 5 ;;
    six) echo 6 ;; seven) echo 7 ;; eight) echo 8 ;; nine) echo 9 ;; ten) echo 10 ;;
    *) echo -1 ;;
  esac
}

# check_bin_tools_count FILE - prints nothing and returns 0 when the
# "N `bin/` tools are never linked" sentence's N matches how many
# `bin/...` entries the Exceptions table's bin/ row actually lists;
# otherwise prints the mismatch and returns 1.
check_bin_tools_count() {
  local f="$1" flat sentence word num row cell count
  flat="$(tr '\n' ' ' < "$f")"
  sentence="$(printf '%s\n' "$flat" | grep -oE "[a-z]+ ${bt}bin/${bt}[[:space:]]*tools are never linked")" || true
  [ -n "$sentence" ] || { echo "no 'N ${bt}bin/${bt} tools are never linked' sentence found"; return 1; }
  word="$(printf '%s\n' "$sentence" | sed -E 's/ .*$//')"
  num="$(word_to_num "$word")"

  row="$(grep -F 'runs them from the checkout' "$f")" || true
  [ -n "$row" ] || { echo "no bin/ tools exceptions row found"; return 1; }
  cell="$(printf '%s\n' "$row" | awk -F'|' '{print $2}')"
  count="$(printf '%s\n' "$cell" | grep -oE "${bt}bin/[a-zA-Z0-9_-]+${bt}" | wc -l | tr -d '[:space:]')"

  if [ "$num" != "$count" ]; then
    echo "doc says \"$word\" ($num) but the row lists $count bin/ tool(s)"
    return 1
  fi
  return 0
}

# --- (a) can-fail proof: a case arm undocumented in the header -----------------
awk '!/^#   install\.sh packages /' "$install" > "$work/mutant_missing"
if out="$(check_subcommand_docs "$work/mutant_missing" 2>&1)"; then
  fail "can-fail proof: deleting the 'packages' header line was NOT caught - this check proves nothing"
fi
case "$out" in *packages*) ok "planting an undocumented case arm (packages) IS caught: $out" ;;
  *) fail "wrong failure reason: $out" ;;
esac

# --- (a) can-fail proof: the header names a subcommand with no arm ------------
awk '{print} /^#   install\.sh -h/{print "#   install.sh frobnicate         not a real subcommand"}' \
  "$install" > "$work/mutant_phantom"
if out="$(check_subcommand_docs "$work/mutant_phantom" 2>&1)"; then
  fail "can-fail proof: a phantom header subcommand was NOT caught - this check proves nothing"
fi
case "$out" in *frobnicate*) ok "planting a phantom header subcommand (frobnicate) IS caught: $out" ;;
  *) fail "wrong failure reason: $out" ;;
esac

# --- (a) can-fail proof: the retired arm leaks into the primary usage list ----
awk '{print} /^#   install\.sh -h/{print "#   install.sh reseed-settings     retired - should not be here"}' \
  "$install" > "$work/mutant_retired_leaked"
if out="$(check_subcommand_docs "$work/mutant_retired_leaked" 2>&1)"; then
  fail "can-fail proof: reseed-settings leaking into the primary usage list was NOT caught - this check proves nothing"
fi
case "$out" in *"belongs only in the retired-arm note"*) ok "the retired arm leaking into the primary usage list IS caught: $out" ;;
  *) fail "wrong failure reason: $out" ;;
esac

# --- (a) can-fail proof: the retired arm drops out of the header --------------
awk '!/reseed-settings is retired/' "$install" > "$work/mutant_no_retired_note"
if out="$(check_subcommand_docs "$work/mutant_no_retired_note" 2>&1)"; then
  fail "can-fail proof: dropping the reseed-settings note was NOT caught - this check proves nothing"
fi
case "$out" in *reseed-settings*) ok "dropping the retired-arm note IS caught: $out" ;;
  *) fail "wrong failure reason: $out" ;;
esac

# --- (a) the real tracked file: case arms and header usage agree --------------
if out="$(check_subcommand_docs "$install" 2>&1)"; then
  ok "install.sh: every case arm is named in the header, and vice versa"
else
  fail "install.sh header/case drift: $out"
fi

# --- (b) can-fail proof: the stated count no longer matches the table ---------
sed "s/and five ${bt}bin\\/${bt}/and four ${bt}bin\\/${bt}/" "$arch_doc" > "$work/mutant_count"
if out="$(check_bin_tools_count "$work/mutant_count" 2>&1)"; then
  fail "can-fail proof: an off-by-one bin/ tool count was NOT caught - this check proves nothing"
fi
case "$out" in *"four"*"5 bin/ tool"*) ok "an off-by-one bin/ tool count IS caught: $out" ;;
  *) fail "wrong failure reason: $out" ;;
esac

# --- (b) the real tracked file: the stated count matches the table ------------
if out="$(check_bin_tools_count "$arch_doc" 2>&1)"; then
  ok "docs/architecture.md: the stated bin/ tool count matches the table row"
else
  fail "docs/architecture.md bin/ tool count drift: $out"
fi

echo "PASS: subcommand_docs_test ($pass assertions)"
