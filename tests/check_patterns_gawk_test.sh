#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# bin/check-patterns arm 15 counts a Markdown line's width in CHARACTERS, and
# picks its counting path by probing the awk it runs under. macOS's awk counts
# bytes, so only gawk under a UTF-8 locale takes the character path in CI,
# through `make check-patterns-gawk` (tests/check_patterns_gawk.py). This
# proves, in order:
#   - the gate: SKIP or STRICT failure with no gawk, or with a gawk that counts
#     bytes in every locale it tries, and PASS on the real gawk; its one stdout
#     line is the local-ci summary's line for this leg;
#   - the seam: CHECK_PATTERNS_AWK and CHECK_PATTERNS_AWK_LC_ALL reach the awk
#     that runs, seen through a logging wrapper rather than inferred from a
#     verdict, so the proof holds whatever the platform's default awk counts;
#   - the character path gives the byte path's verdicts: 60 two-byte
#     characters plus a word are 71 characters (131 bytes) and pass, 81
#     characters fail, and the micro, degree and section signs (second bytes
#     0xB5, 0xB0, 0xA7, the edges of the continuation-byte class) are one
#     column each. gawk under LC_ALL=C is the byte path, so one binary shows
#     both. The case that failed before the seam existed: the byte path's
#     [\200-\277] written as a regex literal is a parse error in gawk under a
#     UTF-8 locale, so the gate died on the awk this leg runs;
#   - every way the seam could make the leg vacuous is exit 2.
# Needs gawk and python3: absent, a loud skip, a failure under STRICT=1.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cp="$repo_root/bin/check-patterns"
gate="$repo_root/tests/check_patterns_gawk.py"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); }

for tool in gawk python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    if [ -n "${STRICT:-}" ]; then fail "$tool not installed and STRICT=1"; fi
    echo "SKIP: check_patterns_gawk_test ($tool unavailable)"; exit 0
  fi
done
# The gate's own probe, so the leg and this test cannot pick differently.
loc="$(python3 -I "$gate" --locale)"
if [ -z "$loc" ]; then
  if [ -n "${STRICT:-}" ]; then fail "no UTF-8 locale makes gawk count characters and STRICT=1"; fi
  echo "SKIP: check_patterns_gawk_test (gawk counts bytes in every UTF-8 locale tried)"; exit 0
fi
gawk_path="$(command -v gawk)"
py_path="$(python3 -I -c 'import sys; print(sys.executable)')"
make_path="$(command -v make)"
env_path="$(command -v env)"

# An unwritable TMPDIR fails this suite loudly here (mktemp's own message,
# then `set -e`), never a silent pass. bin/check-patterns' case is below.
work="$(mktemp -d "${TMPDIR:-/tmp}/check_patterns_gawk_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM
export GIT_CEILING_DIRECTORIES="$work"

# --- the gate -----------------------------------------------------------------
# Each case runs `make check-patterns-gawk` on a PATH that holds a python3 shim
# (the recipe's `command -v python3` must find one) and, when the case wants
# it, a gawk; or nothing at all. make inherits no MAKEFLAGS from an outer
# make: -n, --trace or --debug there would change what this make prints.
stub_none="$work/stub-none"; stub_bytes="$work/stub-bytes"; stub_empty="$work/stub-empty"
mkdir -p "$stub_none" "$stub_bytes" "$stub_empty"
for d in "$stub_none" "$stub_bytes"; do
  printf '#!/bin/sh\nexec %s "$@"\n' "'$py_path'" > "$d/python3"
  chmod u+x "$d/python3"
done
# A gawk that counts bytes in every locale: 2 for the two-byte probe.
printf '#!/bin/sh\necho 2\n' > "$stub_bytes/gawk"
chmod u+x "$stub_bytes/gawk"

# gate WANT_RC PATH STRICT LABEL [MAKE-ARG...] - `make check-patterns-gawk`
# with STRICT in its environment: its stdout in $out, its stderr in $err. A
# failing recipe is make's exit 2. MAKE-ARGs replace the target, for the cases
# that pass their own.
gate() {
  local want="$1" path="$2" strict="$3" label="$4" rc=0
  shift 4
  [ "$#" -gt 0 ] || set -- check-patterns-gawk
  out="$(PATH="$path" STRICT="$strict" "$env_path" -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u GNUMAKEFLAGS \
    "$make_path" -s --no-print-directory -C "$repo_root" "$@" 2>"$work/err")" || rc=$?
  err="$(cat "$work/err")"
  [ "$rc" = "$want" ] || fail "$label: want exit $want, got $rc: $out $err"
}
gate 0 "$stub_empty" "" "neither python3 nor gawk on PATH"
[ "$out" = "check-patterns-gawk: SKIP (python3 not installed; set STRICT=1 to fail, CI enforces it)" ] \
  || fail "no python3 on PATH must print one SKIP verdict line: $out"
ok
gate 2 "$stub_empty" 1 "neither python3 nor gawk on PATH under STRICT=1"
[ -z "$out" ] || fail "no python3 on PATH under STRICT=1 must print no verdict: $out"
case "$err" in
  "ERROR: check-patterns-gawk: python3 not installed and STRICT=1 - failing closed"*) ok ;;
  *) fail "no python3 on PATH under STRICT=1 must say so: $err" ;;
esac
gate 0 "$stub_none" "" "no gawk on PATH"
[ "$out" = "check-patterns-gawk: SKIP (gawk not installed; set STRICT=1 to fail, CI enforces it)" ] \
  || fail "no gawk on PATH must print one SKIP verdict line: $out"
ok
gate 2 "$stub_none" 1 "no gawk on PATH under STRICT=1"
[ -z "$out" ] || fail "no gawk on PATH under STRICT=1 must print no verdict: $out"
case "$err" in
  "ERROR: check-patterns-gawk: gawk not installed and STRICT=1 - failing closed"*) ok ;;
  *) fail "no gawk on PATH under STRICT=1 must say so: $err" ;;
esac
gate 0 "$stub_bytes" "" "a gawk that counts bytes"
case "$out" in
  "check-patterns-gawk: SKIP ($stub_bytes/gawk counts bytes under en_US.UTF-8 and C.UTF-8; "*) ok ;;
  *) fail "a gawk that counts bytes must print one SKIP verdict line: $out" ;;
esac
gate 2 "$stub_bytes" 1 "a gawk that counts bytes under STRICT=1"
[ -z "$out" ] || fail "a gawk that counts bytes under STRICT=1 must print no verdict: $out"
case "$err" in
  "ERROR: check-patterns-gawk: $stub_bytes/gawk counts bytes under "*" and STRICT=1 - failing closed"*) ok ;;
  *) fail "a gawk that counts bytes under STRICT=1 must say so: $err" ;;
esac
# STRICT=1 on make's command line reaches the script too (make exports it).
gate 2 "$stub_none" "" "no gawk on PATH, STRICT=1 on make's command line" check-patterns-gawk STRICT=1
case "$err" in
  "ERROR: check-patterns-gawk: gawk not installed and STRICT=1 - failing closed"*) ok ;;
  *) fail "STRICT=1 on make's command line must reach the gate: $err" ;;
esac
gate 0 "$PATH" "" "the real gawk"
[ "$out" = "check-patterns-gawk: PASS (bin/check-patterns under $gawk_path, LC_ALL=$loc)" ] \
  || fail "the real gawk must print one PASS verdict line: $out"
ok

# local-ci runs the gate from its summary through $(MAKE). The recipe line is
# taken from the real Makefile and run by a makefile that includes it, followed
# by a marker line: a failing gate must stop the recipe there under STRICT=1,
# and a skip must let it go on. The marker names its shell by absolute path,
# since the PATH here has no `echo`: a make whose shell is plain /bin/sh runs a
# simple line without a shell (GNU make's fast path, and what macOS's make 3.81
# did with this Makefile's SHELL := /bin/bash on the CI legs), so a bare `echo`
# would fail as a missing command. Each case runs under both shells, so the
# fast path is covered on any make.
recipe_line="$(awk '/^local-ci:/{p=1} p&&/^$/{exit} p' "$repo_root/Makefile" \
  | grep -E '^[[:space:]]+@\$\(MAKE\)[[:space:]].*[[:space:]]check-patterns-gawk$' || true)"
[ -n "$recipe_line" ] || fail "the local-ci recipe must run \$(MAKE) check-patterns-gawk"
printf "include %s/Makefile\nrecursion-probe:\n%s\n\t@/bin/sh -c 'echo after-the-gate'\n" \
  "$repo_root" "$recipe_line" > "$work/recursion.mk"
for probe_sh in /bin/bash /bin/sh; do
  gate 2 "$stub_none" 1 "local-ci's gate line with no gawk under STRICT=1 (SHELL=$probe_sh)" \
    -f "$work/recursion.mk" recursion-probe SHELL="$probe_sh"
  case "$out" in
    *after-the-gate*) fail "a failing gate under STRICT=1 must stop local-ci's recipe (SHELL=$probe_sh): $out" ;;
  esac
  case "$err" in
    *"ERROR: check-patterns-gawk: gawk not installed and STRICT=1"*) ok ;;
    *) fail "local-ci's gate line under STRICT=1 must say why (SHELL=$probe_sh): $err" ;;
  esac
  gate 0 "$stub_none" "" "local-ci's gate line with no gawk (SHELL=$probe_sh)" \
    -f "$work/recursion.mk" recursion-probe SHELL="$probe_sh"
  [ "$out" = "$(printf '%s\n%s' "check-patterns-gawk: SKIP (gawk not installed; set STRICT=1 to fail, CI enforces it)" after-the-gate)" ] \
    || fail "local-ci's gate line with no gawk must print the SKIP line and go on (SHELL=$probe_sh): $out"
  ok
done

# A bin/check-patterns that fails must fail the gate, never print PASS. The
# script is run from a copy laid out like the repository, beside a stub
# bin/check-patterns, so the gate needs no seam of its own for this.
mkdir -p "$work/fake/tests" "$work/fake/bin"
cat "$gate" > "$work/fake/tests/check_patterns_gawk.py"
printf '#!/bin/sh\nexit 1\n' > "$work/fake/bin/check-patterns"
chmod u+x "$work/fake/bin/check-patterns"
rc=0; out="$(STRICT='' python3 -I "$work/fake/tests/check_patterns_gawk.py" 2>"$work/err")" || rc=$?
err="$(cat "$work/err")"
[ "$rc" = 1 ] || fail "a failing bin/check-patterns must fail the gate with its code, got $rc: $out $err"
[ -z "$out" ] || fail "a failing bin/check-patterns must print no verdict: $out"
case "$err" in
  "ERROR: check-patterns-gawk: bin/check-patterns exited 1 under $gawk_path, LC_ALL=$loc") ok ;;
  *) fail "a failing bin/check-patterns must be named: $err" ;;
esac

# An empty PATH element means the current directory, and shutil.which hands it
# back RELATIVE ("gawk"): the probe resolves it where the gate runs, while
# bin/check-patterns runs from the repository and a BASH_ENV hash entry can
# answer its `command -v` with a third binary. The gate must probe and execute
# the same absolute path: here ./gawk, never the decoy the hash entry names.
# The VERDICT assertion is what bites on the old probe (it printed the bare
# "gawk"); the decoy log is a second guard, for a gate that resolves the name
# through the hash entry, and was not itself seen to fail on the old code.
mkdir -p "$work/emptyel" "$work/decoy"
printf '#!/bin/sh\nexec %s "$@"\n' "'$gawk_path'" > "$work/emptyel/gawk"
printf '#!/bin/sh\necho ran >> %s\nexec %s "$@"\n' "'$work/decoy.log'" "'$gawk_path'" > "$work/decoy/gawk"
chmod u+x "$work/emptyel/gawk" "$work/decoy/gawk"
printf 'hash -p %s gawk\n' "'$work/decoy/gawk'" > "$work/hash.env"
# The working directory is the PHYSICAL path (getcwd), whatever way TMPDIR is
# spelled: under a symlinked TMPDIR $work is not it.
emptyel="$(cd "$work/emptyel" && pwd -P)"
rc=0; out="$(cd "$work/emptyel" && PATH=":$PATH" BASH_ENV="$work/hash.env" STRICT='' \
  python3 -I "$gate" 2>"$work/err")" || rc=$?
err="$(cat "$work/err")"
[ "$rc" = 0 ] || fail "an empty PATH element and a BASH_ENV hash entry: want exit 0, got $rc: $out $err"
[ "$out" = "check-patterns-gawk: PASS (bin/check-patterns under $emptyel/gawk, LC_ALL=$loc)" ] \
  || fail "the verdict must name the absolute path of the gawk probed: $out"
[ ! -e "$work/decoy.log" ] || fail "the gawk a BASH_ENV hash entry names ran instead of the one probed"
ok

# --- the seam -----------------------------------------------------------------
# A tree no other arm objects to, holding one Markdown file.
r="$work/tree"; mkdir -p "$r/lib" "$r/docs"
printf 'noop() { : ; }\n' > "$r/lib/os.sh"
printf 'short line\n' > "$r/docs/x.md"
# A logging awk: one line per call that carries the width arm's W=, with the
# name it was called by, the LC_ALL it got and what it read (`stdin` for the
# positive control, `file` for the scan of the tree), then the real gawk.
# Other arms call awk too, and their calls carry no W=.
log="$work/awk.log"
mkdir -p "$work/shadow"
cat > "$work/logawk" <<EOF
#!/bin/sh
w=''; last=''
for a in "\$@"; do
  case "\$a" in W=*) w="\$a" ;; esac
  last="\$a"
done
if [ -n "\$w" ]; then
  if [ -f "\$last" ]; then src=file; else src=stdin; fi
  printf '%s %s %s %s\\n' "\${0##*/}" "LC_ALL=\${LC_ALL-unset}" "\$w" "\$src" >> '$log'
fi
exec '$gawk_path' "\$@"
EOF
chmod u+x "$work/logawk"
cat "$work/logawk" > "$work/shadow/awk"
chmod u+x "$work/shadow/awk"
# clean LABEL ENV... - bin/check-patterns on the clean tree under `env ENV...`
# must pass; its output is kept for the failure message only.
clean() {
  local label="$1" out
  shift
  out="$("$env_path" STRICT='' "$@" "$cp" "$r" 2>&1)" || fail "$label on a clean tree must pass: $out"
}
# logged CALL LABEL - the width arm ran exactly twice since the last reset, as
# CALL both times: once on the control line, then once on the tree's one file.
logged() {
  local want
  want="$(printf '%s stdin\n%s file' "$1" "$1")"
  [ "$(cat "$log")" = "$want" ] || fail "$2: want '$want', got: '$(cat "$log")'"
  : > "$log"; ok
}
: > "$log"
clean "the seam pair" CHECK_PATTERNS_AWK="$work/logawk" CHECK_PATTERNS_AWK_LC_ALL="$loc"
logged "logawk LC_ALL=$loc W=80" "the seam pair must run the named awk under the named locale"
# The default locale is C even when the caller's own LC_ALL is a UTF-8 one.
clean "the named awk alone" LC_ALL="$loc" CHECK_PATTERNS_AWK="$work/logawk"
logged "logawk LC_ALL=C W=80" "with no CHECK_PATTERNS_AWK_LC_ALL the awk must run under C"
# The default awk is the `awk` on PATH, under C, whether the seam is unset or
# set but empty.
clean "the default awk" PATH="$work/shadow:$PATH" LC_ALL="$loc"
logged "awk LC_ALL=C W=80" "with no seam set the width check must run PATH's awk under C"
clean "an empty seam" PATH="$work/shadow:$PATH" CHECK_PATTERNS_AWK='' CHECK_PATTERNS_AWK_LC_ALL=''
logged "awk LC_ALL=C W=80" "an empty CHECK_PATTERNS_AWK must fall back to PATH's awk under C"
# The gate itself, with the logging awk as the gawk on PATH: what it hands
# bin/check-patterns is what the width awk receives, the locale it probed
# included. It scans the whole repository, so the scan may be several calls.
mkdir -p "$work/gshim"
cat "$work/logawk" > "$work/gshim/gawk"
chmod u+x "$work/gshim/gawk"
gate 0 "$work/gshim:$PATH" "" "the gate on a logging gawk"
[ "$out" = "check-patterns-gawk: PASS (bin/check-patterns under $work/gshim/gawk, LC_ALL=$loc)" ] \
  || fail "the gate on a logging gawk must pass, naming it: $out"
[ "$(sed -n 1p "$log")" = "gawk LC_ALL=$loc W=80 stdin" ] \
  || fail "the gate must run the control under its probed locale first: $(cat "$log")"
if grep -vqxF -e "gawk LC_ALL=$loc W=80 stdin" -e "gawk LC_ALL=$loc W=80 file" "$log"; then
  fail "every width call through the gate must run its gawk under $loc: $(cat "$log")"
fi
grep -qxF "gawk LC_ALL=$loc W=80 file" "$log" || fail "the gate must scan files: $(cat "$log")"
: > "$log"; ok
# Only a NAMED locale demands the character path: an awk that counts
# characters under the default C (here gawk, handed a UTF-8 locale by its own
# wrapper) is as valid as one that counts bytes.
printf '#!/bin/sh\nexec %s LC_ALL=%s %s "$@"\n' "'$env_path'" "'$loc'" "'$gawk_path'" > "$work/u8awk"
chmod u+x "$work/u8awk"
clean "an awk that counts characters under the default locale" CHECK_PATTERNS_AWK="$work/u8awk"
ok

# --- the character path gives the byte path's verdicts -------------------------
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
  out="$(STRICT='' CHECK_PATTERNS_AWK=gawk CHECK_PATTERNS_AWK_LC_ALL="$2" "$cp" "$r" 2>&1)" || rc=$?
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
    # $mb is the FORMAT on purpose: printf expands its octal escapes into the
    # two bytes of the character (SC2059 would have it as an argument).
    # shellcheck disable=SC2059
    printf '%s %s\n' "$(words 78)" "$(printf "$mb")" > "$r/docs/x.md"
    expect 0 "$lc" "80 characters ending in $mb must pass"
    # shellcheck disable=SC2059
    printf '%s %s\n' "$(words 79)" "$(printf "$mb")" > "$r/docs/x.md"
    expect 1 "$lc" "81 characters ending in $mb must fail"
  done
done

# Invalid UTF-8 is where the two paths part: a lone continuation byte is one
# character to gawk in a UTF-8 locale and zero columns on the byte path (which
# deletes 0x80-0xBF). 79 columns, a space and two such bytes are 82 on the
# character path and 80 on the byte path.
printf '%s \251\251\n' "$(words 79)" > "$r/docs/x.md"
expect 1 "$loc" "invalid UTF-8 must count as characters on gawk's character path"
expect 0 C "the same bytes must be deleted on gawk's byte path"

# --- every way the seam could make the leg vacuous is exit 2 -------------------
printf 'short line\n' > "$r/docs/x.md"
# expect2 NEEDLE LABEL [VAR=VALUE...] - bin/check-patterns exits 2, saying NEEDLE.
expect2() {
  local needle="$1" label="$2" rc=0 out
  shift 2
  out="$(env STRICT= "$@" "$cp" "$r" 2>&1)" || rc=$?
  [ "$rc" = 2 ] || fail "$label: want exit 2, got $rc: $out"
  case "$out" in
    *"$needle"*) ok ;;
    *) fail "$label: must say '$needle': $out" ;;
  esac
}
# A name that is no executable file: absent, a builtin, a relative path, an
# option. And a real gawk whose path holds `=`, which `env` would take for a
# variable assignment.
mkdir -p "$work/eq"
ln -s "$gawk_path" "$work/eq/g=awk"
for bad in no-such-awk-here cd ./gawk -F "$work/eq/g=awk"; do
  expect2 "CHECK_PATTERNS_AWK names '$bad'" "CHECK_PATTERNS_AWK=$bad" CHECK_PATTERNS_AWK="$bad"
done
# A locale gawk does not know: it falls back to C, silently, and counts bytes.
expect2 "counts bytes under the locale CHECK_PATTERNS_AWK_LC_ALL names" \
  "an unknown CHECK_PATTERNS_AWK_LC_ALL" CHECK_PATTERNS_AWK=gawk CHECK_PATTERNS_AWK_LC_ALL=bogus
# An executable that checks nothing and exits 0.
printf '#!/bin/sh\nexit 0\n' > "$work/true"
chmod u+x "$work/true"
expect2 "did not report the over-width control line" \
  "an awk that reports nothing" CHECK_PATTERNS_AWK="$work/true"
# No scratch dir, no fail-closed evidence.
expect2 "could not create a scratch dir" \
  "an unwritable TMPDIR" TMPDIR="$work/no-such-dir" CHECK_PATTERNS_AWK=gawk CHECK_PATTERNS_AWK_LC_ALL="$loc"

echo "PASS: check_patterns_gawk_test ($pass assertions)"
