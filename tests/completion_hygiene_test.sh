#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Static hygiene gate for zsh COMPLETION functions (the #33 static-tool candidate
# a completion test that never exercises a VALUE position passes vacuously).
#
# THE DEFECT CLASS this closes (shipped green in the dev/dotfiles-*
# completion, caught only by the 3-persona ship): a completion function that opens
# with `emulate -L zsh` locally disables extended_glob, which the compsys helper
# `_files -/` needs for its `*(#q-/)` directory glob - so directory positions throw
# `bad pattern` instead of completing. A completion function must instead INHERIT
# the completion system's option environment (no `emulate`).
#
# Why a TEST and not a `bin/check-patterns` rule: check-patterns DOES scan zsh/
# (bin/check-patterns:50), but it is a per-LINE grep gate; this class needs
# MULTI-LINE, function-scope correlation - `emulate` on one line AND a compsys
# helper on another, WITHIN the same function body - which a per-line matcher
# cannot express. Hence the awk scan below.
#
# The check flags any completion-shaped function in zsh/*.zsh that contains BOTH
# an `emulate -L[R] zsh` reset AND a compsys ACTION helper (`_files`, `_arguments`,
# `_describe`, `_values`, `_alternative`, `_directories`, `_wanted`,
# `_regex_arguments`, `_path_files`, `compadd`). Precise: it does NOT flag pure
# PARSER helpers that legitimately emulate (a pure parser - emulate, no
# compsys), nor correct completions (compsys, no emulate).
#
# bash 3.2 compatible; awk-based; not part of the shellcheck surface.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); echo "  ok: $1"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/completion_hygiene.XXXXXX")"; trap 'rm -rf "$work"' EXIT

# --- the checker ---------------------------------------------------------------
# Function scope: an opener at column 0 in any of zsh's forms - `name() {`,
# `name () {`, `function name {`, `function name() {` - opens; a `}` at column 0
# closes (nested braces in `_arguments` specs like `{-h,--help}` are indented, so
# they never falsely close a top-level function). One-liners close on their line.
# Comments are stripped before matching, but ONLY a `#` that starts a token -
# `sub(/(^|[[:space:]])#.*/, "", t)` - i.e. a genuine comment. A `#` that follows
# `{`/`$`/`(` (as in `${#names}`, `$#`, `*(#q-/)`) is PRESERVED, so it cannot mask a
# real call like `(( ${#names} )) && compadd …` - the standard guarded-compadd idiom
# (planted as a fixture below). This still spares a function's own
# "# NO `emulate` here … `_files`" note - whole-line or trailing - from self-tripping.
# (Two false positives shaped this: the self-note, and the `${#}` masking the ship's
# code-reviewer caught.) FNR (not cumulative NR) reports the per-file line; state
# resets at each file so an unclosed function can't bleed over.
CH='(_files|_path_files|_directories|_arguments|_describe|_values|_alternative|_wanted|_regex_arguments|compadd)'
EM='emulate -L[R]? zsh'
cat > "$work/check.awk" <<AWK
function nameof(s) { sub(/^function[[:space:]]+/, "", s); sub(/[[:space:]]*\(.*/, "", s); sub(/[[:space:]]*\{.*/, "", s); return s }
FNR==1 { infn=0; e=0; c=0 }
/^(function[[:space:]]+_[A-Za-z0-9_-]+([[:space:]]*\(\))?|_[A-Za-z0-9_-]+[[:space:]]*\(\))[[:space:]]*\{/ {
  fn=nameof(\$0); infn=1; e=0; c=0; sl=FNR
  if (\$0 ~ /\}[[:space:]]*\$/) {                # one-liner: opens and closes here
    t=\$0; sub(/(^|[[:space:]])#.*/, "", t)
    if (t ~ /$EM/ && t ~ /$CH/) { print FILENAME":"FNR": "fn; rc=1 }
    infn=0
  }
  next
}
infn {
  t=\$0; sub(/(^|[[:space:]])#.*/, "", t)       # strip a comment-# (token-start only), NOT \${#}/\$#/(#
  if (t ~ /$EM/) e=1
  if (t ~ /$CH/) c=1
  if (\$0 ~ /^\}/) { if (e && c) { print FILENAME":"sl": "fn; rc=1 } infn=0 }
}
END { exit rc+0 }
AWK
check() { awk -f "$work/check.awk" "$@"; }   # exit 0 clean, 1 flagged

# --- 1. the REAL tree is clean: no completion function emulates-with-compsys -----
zfiles=(); while IFS= read -r f; do zfiles+=("$repo_root/$f"); done < <(cd "$repo_root" && git ls-files '*.zsh')
out="$(check "${zfiles[@]}" 2>/dev/null || true)"
[ -z "$out" ] || fail "a zsh completion function uses 'emulate' with a compsys helper (breaks _files):"$'\n'"$out"
ok "no completion function in the tree emulates with a compsys helper"

# check_and_expect LABEL FIXTURE-CONTENT EXPECT(flag|clean) [NAME-if-flag] --------
# captures first (check exits 1 when flagging; a `check | grep` pipe would fail on
# check's exit under pipefail, not grep's - so grab output, then match it).
check_and_expect() {
  local label="$1" content="$2" expect="$3" name="${4:-}" f rc=0 o
  f="$work/fx_$$_${RANDOM}.zsh"; printf '%s\n' "$content" > "$f"
  o="$(check "$f" 2>/dev/null || true)"; [ -n "$o" ] && rc=1
  if [ "$expect" = flag ]; then
    [ "$rc" -eq 1 ] || fail "$label: expected FLAG, got clean"
    [ -z "$name" ] || printf '%s\n' "$o" | grep -q -- "$name" || fail "$label: flagged but did not name '$name' (got [$o])"
  else
    [ "$rc" -eq 0 ] || fail "$label: expected CLEAN, got flag [$o]"
  fi
  rm -f "$f"; ok "$label"
}

# --- 2. RED: planted violations ARE flagged (each proves the gate can fail) ------
check_and_expect "planted emulate+_files completion IS flagged (RED, named)" \
  '_bad-complete() {
  emulate -L zsh
  _arguments "--root[dir]:dir:_files -/"
}' flag '_bad-complete'

# HIGH-1: a compadd-based completion is in scope (a compadd wrapper must not be a
# blind spot).
check_and_expect "planted emulate+compadd completion IS flagged" \
  '_bad-compadd() {
  emulate -L zsh
  compadd alpha beta
}' flag '_bad-compadd'

# HIGH-1 (the LIVE shape): the guarded `(( ${#arr} )) && compadd` idiom - the `#` in
# ${#arr} is a length op, NOT a comment, and must not mask the compadd. This mirrors
# the standard guarded-compadd idiom; the ship code-reviewer caught
# the earlier `sub(/#.*/)` strip silently clearing exactly this.
check_and_expect "planted guarded 'emulate; (( \${#a} )) && compadd' IS flagged" \
  '_bad-guarded() {
  emulate -L zsh
  (( ${#names} )) && compadd -a names
}' flag '_bad-guarded'

# HIGH-2: the `function name {` opener form is caught.
check_and_expect "planted 'function _x {' form IS flagged" \
  'function _bad-fnform {
  emulate -L zsh
  _files -/
}' flag '_bad-fnform'

# HIGH-2: the `emulate -LR zsh` reset variant is caught (breaks extended_glob too).
check_and_expect "planted 'emulate -LR zsh' IS flagged" \
  '_bad-lr() {
  emulate -LR zsh
  _files -/
}' flag '_bad-lr'

# a one-liner emulate+compsys on a single line is caught.
check_and_expect "one-line emulate+_files completion IS flagged" \
  '_oneliner() { emulate -L zsh; _files -/ }' flag '_oneliner'

# --- 3/4. discrimination: parsers-with-emulate and correct-completions NOT flagged
check_and_expect "parser (emulate, NO compsys helper) is NOT flagged" \
  '_names_from() {
  emulate -L zsh
  print -r -- "$1" | while read -r nm; do print -r -- "$nm"; done
}' clean

check_and_expect "correct completion (compsys, NO emulate) is NOT flagged" \
  '_good-complete() {
  _arguments "--arch:arch:(arm64 amd64)" ":dir:_files -/"
}' clean

# a function whose compsys helper appears ONLY in a comment is NOT flagged.
check_and_expect "compsys helper only in a comment is NOT flagged" \
  '_documented() {
  emulate -L zsh   # this one legitimately parses; mentions _files in prose only
  print -r -- "$1"
}' clean

# === F2 (registration integrity): every `compdef _x cmd` names a
# === DEFINED `_x` (or a known compsys builtin) - a dangling / typo'd / stale-after-
# === rename compdef registers a completion for a function that does not exist. Cross-
# === file over the tracked zsh set. Direction B (an unregistered completion) is
# === intentionally NOT checked: compadd action helpers are functions
# === but not compdef entry points, so it would false-positive.
# === SCOPE (honest quantifier, NOT "false-positive-free" in general): only the bare
# === `compdef _fn cmd` form is checked; a token-start comment is stripped so a
# === `# compdef _x` note cannot self-trip (mirroring check.awk); compsys BUILTINS
# === compdef'd without a repo definition (_gnu_generic/_precommand/_normal/_default/
# === _man) are allowlisted (extend the list if a new one is registered); and the
# === flag/alias forms (`compdef -e`, `compdef _x=_y`) are out of scope - a safe
# === omission, the anchored name guard rejects them rather than mis-parsing.
cat > "$work/reg.awk" <<'AWK'
BEGIN { split("_gnu_generic _precommand _normal _default _man", b, " "); for (i in b) builtin[b[i]]=1 }
{ t=$0; sub(/(^|[[:space:]])#.*/, "", t) }   # a token-start comment cannot mask a compdef
/^(function[[:space:]]+_[A-Za-z0-9_-]+([[:space:]]*\(\))?|_[A-Za-z0-9_-]+[[:space:]]*\(\))[[:space:]]*\{/ {
  n=$0; sub(/^function[[:space:]]+/,"",n); sub(/[[:space:]]*\(.*/,"",n); sub(/[[:space:]]*\{.*/,"",n); defined[n]=1
}
t ~ /(^|[[:space:];&|])compdef[[:space:]]+_[A-Za-z0-9_-]+([[:space:]]|$)/ {
  s=t; sub(/.*compdef[[:space:]]+/,"",s); sub(/[[:space:]].*/,"",s)
  if (s ~ /^_[A-Za-z0-9_-]+$/) ref[s]=FILENAME":"FNR
}
END { for (n in ref) if (!(n in defined) && !(n in builtin)) { print ref[n]": compdef registers undefined function "n; rc=1 } exit rc+0 }
AWK
check_reg() { awk -f "$work/reg.awk" "$@"; }

out="$(check_reg "${zfiles[@]}" 2>/dev/null || true)"
[ -z "$out" ] || fail "a compdef registers a completion for an UNDEFINED function:"$'\n'"$out"
ok "every compdef in the tree names a defined completion function"

# RED: a compdef to a NONEXISTENT function is flagged (proves the gate can fail)
rf="$work/reg_bad.zsh"
printf '%s\n' '_real() { _files -/ }' 'compdef _real realcmd' 'compdef _missing missingcmd' > "$rf"
o="$(check_reg "$rf" 2>/dev/null || true)"
printf '%s' "$o" | grep -q -- '_missing' || fail "a compdef to an undefined function (_missing) must be flagged (got [$o])"
ok "a dangling compdef (_missing) is flagged"

# CLEAN: a defined function + its matching compdef is not flagged
rf="$work/reg_ok.zsh"
printf '%s\n' '_ok() { _files -/ }' 'compdef _ok okcmd' > "$rf"
[ -z "$(check_reg "$rf" 2>/dev/null || true)" ] || fail "a defined function with a matching compdef must be clean"
ok "a registered, defined completion is clean"

# CLEAN (Direction B off): an unregistered action HELPER is NOT demanded to register
rf="$work/reg_helper.zsh"
printf '%s\n' '_helper_only() { print -r -- x }' '_entry() { _files -/ }' 'compdef _entry entrycmd' > "$rf"
[ -z "$(check_reg "$rf" 2>/dev/null || true)" ] || fail "an unregistered action helper must NOT be flagged (Direction B is intentionally off)"
ok "an unregistered helper is not flagged (no false positive)"

# CLEAN: a token-start comment mentioning `compdef _x` does NOT self-trip (comment-strip)
rf="$work/reg_comment.zsh"
printf '%s\n' '_ok() { _files -/ }' 'compdef _ok okcmd' '# example: compdef _ghost ghostcmd' > "$rf"
[ -z "$(check_reg "$rf" 2>/dev/null || true)" ] || fail "a commented '# compdef _ghost' must NOT be flagged (comment-strip)"
ok "a commented-out compdef is not flagged"

# CLEAN: a compdef to a compsys BUILTIN (not repo-defined) is allowlisted, not flagged
rf="$work/reg_builtin.zsh"
printf '%s\n' 'compdef _gnu_generic mytool' > "$rf"
[ -z "$(check_reg "$rf" 2>/dev/null || true)" ] || fail "a compdef to a compsys builtin (_gnu_generic) must NOT be flagged (allowlist)"
ok "a compdef to a compsys builtin is allowlisted"

# CLEAN: the `function _x() {` opener (keyword AND parens) is recognized as a definition
rf="$work/reg_fnparen.zsh"
printf '%s\n' 'function _combo() { _files -/ }' 'compdef _combo combocmd' > "$rf"
[ -z "$(check_reg "$rf" 2>/dev/null || true)" ] || fail "a 'function _x() {' opener + its compdef must be clean (opener regex)"
ok "the 'function _x() {' opener form is recognized"

# --- 5. the assertion count is asserted, not merely printed (no silent drop) -----
[ "$pass" -eq 17 ] || fail "expected 17 assertions, ran $pass (a case was dropped)"

echo "PASS: completion_hygiene_test ($pass assertions)"
