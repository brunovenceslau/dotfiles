#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# bin/check-patterns arm 15 counts a Markdown line's width in CHARACTERS, and
# picks its counting path by probing the awk it runs under. macOS's awk and
# mawk count bytes, so only gawk under a UTF-8 locale takes the character path
# in CI. This proves the CHECK_PATTERNS_AWK seam reaches that path and that it
# gives the byte path's verdicts: 60 two-byte characters plus a word are 71
# characters (131 bytes) and pass, 81 characters fail, and the micro, degree
# and section signs (second bytes 0xB5, 0xB0, 0xA7, the edges of the
# continuation-byte class) are one column each. gawk under LC_ALL=C is the byte
# path, so one binary shows both. The case that failed before the seam
# existed: the byte path's [\200-\277] written as a regex literal is a parse
# error in gawk under a UTF-8 locale, so the gate died on the awk this leg runs.
# Needs gawk: absent, a loud skip, a failure under STRICT=1 (CI installs it).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cp="$repo_root/bin/check-patterns"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); }

if ! command -v gawk >/dev/null 2>&1; then
  if [ -n "${STRICT:-}" ]; then fail "gawk not installed and STRICT=1"; fi
  echo "SKIP: check_patterns_gawk_test (gawk unavailable)"; exit 0
fi
loc=""
for l in en_US.UTF-8 C.UTF-8; do
  if [ "$(LC_ALL=$l gawk 'BEGIN { print length("\303\251") }' 2>/dev/null)" = 1 ]; then loc=$l; break; fi
done
if [ -z "$loc" ]; then
  if [ -n "${STRICT:-}" ]; then fail "no UTF-8 locale makes gawk count characters and STRICT=1"; fi
  echo "SKIP: check_patterns_gawk_test (gawk counts bytes in every UTF-8 locale tried)"; exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/check_patterns_gawk_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM
export GIT_CEILING_DIRECTORIES="$work"

# A tree no other arm objects to, holding one Markdown file.
r="$work/tree"; mkdir -p "$r/lib" "$r/docs"
printf 'noop() { : ; }\n' > "$r/lib/os.sh"
md_msg="check-patterns: a Markdown prose line over 80 columns"
words() {  # N -> N columns of "aaaa aaaa ... a"
  local s=""
  while [ "${#s}" -lt "$1" ]; do s="${s}aaaa "; done
  s="${s:0:$1}"
  [ "${s: -1}" != " " ] || s="${s%?}b"
  printf '%s' "$s"
}
# expect RC LOCALE LABEL - the gate under gawk in LOCALE on docs/x.md.
expect() {
  local want="$1" rc=0 out
  out="$(STRICT= CHECK_PATTERNS_AWK=gawk CHECK_PATTERNS_AWK_LC_ALL="$2" "$cp" "$r" 2>&1)" || rc=$?
  [ "$rc" = "$want" ] || fail "$3 (locale $2): want exit $want, got $rc: $out"
  if [ "$want" = 1 ]; then
    case "$out" in
      *"/docs/x.md:1:"*"$md_msg"*) ;;
      *) fail "$3 (locale $2): the violation must name docs/x.md:1: $out" ;;
    esac
  fi
  ok
}

accents="$(printf '\303\251%.0s' $(seq 1 60))"
for lc in "$loc" C; do   # the character path, then the byte path: same verdicts
  printf '%s aaaaaaaaaa\n' "$accents" > "$r/docs/x.md"
  expect 0 "$lc" "71 characters of two-byte UTF-8 must pass"
  printf '%s %s\n' "$accents" "$(printf 'a%.0s' $(seq 1 20))" > "$r/docs/x.md"
  expect 1 "$lc" "81 characters must fail"
  for mb in '\302\265' '\302\260' '\302\247'; do
    printf '%s %s\n' "$(words 78)" "$(printf "$mb")" > "$r/docs/x.md"
    expect 0 "$lc" "80 characters ending in $mb must pass"
    printf '%s %s\n' "$(words 79)" "$(printf "$mb")" > "$r/docs/x.md"
    expect 1 "$lc" "81 characters ending in $mb must fail"
  done
done

# An awk that is not there is exit 2, never a fallback to the default awk.
rc=0; out="$(STRICT= CHECK_PATTERNS_AWK=no-such-awk-here "$cp" "$r" 2>&1)" || rc=$?
[ "$rc" = 2 ] || fail "a missing CHECK_PATTERNS_AWK must exit 2, got $rc: $out"
case "$out" in
  *"CHECK_PATTERNS_AWK names 'no-such-awk-here'"*) ok ;;
  *) fail "a missing CHECK_PATTERNS_AWK must say so: $out" ;;
esac

echo "PASS: check_patterns_gawk_test ($pass assertions)"
