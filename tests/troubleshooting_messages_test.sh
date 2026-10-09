#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Doc-sync test: docs/troubleshooting.md is keyed to the exact text the
# framework prints, so a reworded message silently strands its section. This
# test is the one authoritative list of which quoted messages are held to the
# code; other pages summarize it and point here.
#
# Docs to code. What counts as a quoted message:
#   * a line inside a fenced block that starts with `install: `, `dotfiles: `
#     or `check-patterns: `, read from both docs/troubleshooting.md and
#     docs/signing-key.md (the `install: ` prefix is added by a helper -
#     install.sh's log/warn and lib/host_identity.py's PREFIX - so the code's
#     literal lacks it and it is dropped; the few lines install.sh prints with
#     it inline still match as substrings);
#   * a backtick span that starts with one of the framework's message prefixes,
#     read from docs/troubleshooting.md only (`install: `, dropped like the
#     fenced form, `upgrade: `, `link: `, `packages: `, `uninstall: `,
#     `identity: `, `doctor: `, `check-patterns: `, `one or more links`,
#     `updates are available`, `no successful update check`).
# In both, a `doctor: <check>: ` head is composed by doctor() from its CHECKS
# registry, so it is checked as a CHECKS entry, and a `note: ` right after it
# is composed there too and dropped; the text after them is checked on its own.
#
# Placeholders (`<path>`, `...`, a number such as the 30 in "30 days") stand for
# values the code interpolates, so each message is split at them and every
# literal fragment of 8 or more characters must appear verbatim in the code
# (install.sh, lib/*.sh, lib/*.py, zsh/zshrc, zsh/*.zsh and bin/check-patterns,
# searched as one flattened file; a shorter fragment is skipped).
#
# Code to docs: every finding `install.sh doctor` can print as a problem or a
# note must appear in docs/troubleshooting.md. The findings are read from the
# syntax tree of lib/host_identity.py: each Doctor.problem() and Doctor.info()
# argument (a literal, a `%` on one, either branch of a conditional, or a
# local name bound only to those), gitconfig_finding()'s problem and info
# texts, and doctor()'s own `reason` lines. Each is split at its `%`
# conversions, and every fragment of 8 or more characters must appear in the
# page, runs of white space read as one space since the page may wrap them. A
# finding passed on from the identity step (RELAYED below) is that step's
# line, quoted under its own section, not a literal of doctor's; any other
# argument that is no literal fails the test. A local name counts as a
# literal only when every binding of it is a plain `name = ...` of one; a
# `+=`, a loop target or any other binding fails the test. Only calls on
# `self` are read: a finding printed through another name for the Doctor
# (`d = self; d.problem(...)`) is not scanned, and none exists today.
#
# Bash 3.2 compatible (the macOS CI legs run tests under /bin/bash).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
doc="$repo_root/docs/troubleshooting.md"
recipes="$repo_root/docs/signing-key.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$doc" ] || fail "docs/troubleshooting.md not found"
[ -f "$recipes" ] || fail "docs/signing-key.md not found"

work="$(mktemp -d "${TMPDIR:-/tmp}/troubleshooting_messages_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The code that prints the messages, flattened into one searchable file.
cat "$repo_root/install.sh" "$repo_root"/lib/*.sh "$repo_root"/lib/*.py "$repo_root"/zsh/zshrc "$repo_root"/zsh/*.zsh \
  "$repo_root/bin/check-patterns" > "$work/code"

# doctor composes `doctor: <check>: [note: ]<text>` from its CHECKS registry
# (lib/host_identity.py): the check name must be a registry entry, and the
# text is checked on its own. Applied to both shapes below.
doctor_head() {
  awk '{
    if (match($0, /^doctor: [^:<]+: /)) {
      name = substr($0, 9, RLENGTH - 10)
      print "(\"" name "\", Doctor."
      $0 = substr($0, RLENGTH + 1)
      sub(/^note: /, "")
    }
    print
  }'
}
# 1. Fenced-block lines.
awk '/^```/ { inblock = !inblock; next }
     inblock && /^(install|dotfiles|check-patterns): / { sub(/^install: /, ""); print }' "$doc" "$recipes" \
  | doctor_head > "$work/msgs"
# 2. Backtick spans with a message prefix. Today exactly one `install: ` span
# exists (the root refusal in the symptom table) and it is also a prefix of a
# fenced line, so dropping `install: ` from this rule would leave the suite
# green; it is kept for the next span that stands alone. `uninstall: ` matches
# no span today and is kept for the same reason.
grep -oE '`[^`]+`' "$doc" | sed 's/^`//; s/`$//' \
  | grep -E '^(install: |upgrade: |link: |packages: |uninstall: |identity: |doctor: |check-patterns: |one or more links|updates are available|no successful update check)' \
  | sed 's/^install: //' > "$work/spans" || true
doctor_head < "$work/spans" >> "$work/msgs"

# Two floors, because the span scan is a small share of the total: a broken
# fenced scan trips the first (about 265 messages today, 150 leaves room to trim
# the page), a broken span scan only trips the second (about 35 today).
nspans="$(grep -c . "$work/spans" || true)"
[ "$nspans" -ge 28 ] || fail "extracted only $nspans backtick-span messages (span scan rot?)"
count="$(grep -c . "$work/msgs" || true)"
[ "$count" -ge 150 ] || fail "extracted only $count messages from the page (extraction rot?)"

checked=0
while IFS= read -r msg; do
  [ -n "$msg" ] || continue
  # Split at placeholders: <...>, a literal "...", and digit runs.
  # awk, not sed: BSD sed does not turn \n in a replacement into a newline.
  printf '%s\n' "$msg" | awk '{ gsub(/<[^>]*>/, "\n"); gsub(/\.\.\./, "\n"); gsub(/[0-9]+/, "\n"); print }' > "$work/frags"
  while IFS= read -r frag; do
    [ "${#frag}" -ge 8 ] || continue
    grep -qF -- "$frag" "$work/code" \
      || fail "troubleshooting.md quotes a message the code no longer prints: [$msg] (missing fragment: [$frag])"
    checked=$((checked + 1))
  done < "$work/frags"
done < "$work/msgs"

# 3. Code to docs: doctor's findings, read from the module's syntax tree.
if ! command -v python3 >/dev/null 2>&1; then
  if [ -n "${STRICT:-}" ]; then fail "python3 not installed and STRICT=1"; fi
  echo "SKIP: troubleshooting_messages_test code-to-docs leg (python3 unavailable)"
  echo "PASS: troubleshooting_messages_test ($count messages, $checked fragments; doctor findings not checked)"
  exit 0
fi
cat > "$work/findings.py" <<'EOF'
import ast, re, sys

# Doctor calls whose text is the identity step's own line, passed on: the
# agent's refusal (_bare()), the stale-key report (finding, from
# _grouped()), and ~/.gitconfig's finding, whose literals are
# gitconfig_finding()'s and are read there.
RELAYED = {("ssh_agent", "_bare(why)"), ("signing_key", "finding"), ("gitconfig", "finding")}
CONVERSION = re.compile(r"%(?:\([^)]*\))?[-#0 +]*(?:\*|\d+)?(?:\.(?:\*|\d+))?[hlL]?[diouxXeEfFgGcrsa%]")

source, page = (open(p, encoding="utf-8").read() for p in sys.argv[1:3])
flat = " ".join(page.split())
problems, templates = [], []


def resolve(node, func):
    """The literal templates NODE can be, or None when it is not one."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return [node.value]
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mod):
        return resolve(node.left, func)
    if isinstance(node, ast.IfExp):
        a, b = resolve(node.body, func), resolve(node.orelse, func)
        return a + b if a is not None and b is not None else None
    if isinstance(node, ast.Name):
        assigns = [n for n in ast.walk(func) if isinstance(n, ast.Assign)
                   and any(isinstance(t, ast.Name) and t.id == node.id for t in n.targets)]
        plain = set(id(t) for n in assigns for t in n.targets)
        # Every other binding of the name (`+=`, an annotated or a walrus
        # assignment, a loop or `with` target, a tuple target, a parameter)
        # gives it text this scan cannot read, so the name is no literal.
        stores = [n for n in ast.walk(func) if isinstance(n, ast.Name) and n.id == node.id
                  and isinstance(n.ctx, ast.Store)]
        params = ([a.arg for a in ast.walk(func.args) if isinstance(a, ast.arg)]
                  + [h.name for h in ast.walk(func) if isinstance(h, ast.ExceptHandler)])
        if any(id(n) not in plain for n in stores) or node.id in params:
            return None
        out = [resolve(n.value, func) for n in assigns]
        return sum(out, []) if assigns and None not in out else None
    return None


def take(node, func, where):
    got = resolve(node, func)
    if got is None:
        problems.append("%s: line %d passes %s, which is no literal" % (where, node.lineno, ast.unparse(node)))
    else:
        templates.extend(got)


for top in ast.parse(source).body:
    if isinstance(top, ast.ClassDef) and top.name == "Doctor":
        for func in top.body:
            if not isinstance(func, ast.FunctionDef):
                continue
            for n in ast.walk(func):
                if (isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr in ("problem", "info")
                        and isinstance(n.func.value, ast.Name) and n.func.value.id == "self" and n.args
                        and (func.name, ast.unparse(n.args[0])) not in RELAYED):
                    take(n.args[0], func, "Doctor." + func.name)
    elif isinstance(top, ast.FunctionDef) and top.name == "gitconfig_finding":
        for n in ast.walk(top):
            if (isinstance(n, ast.Return) and isinstance(n.value, ast.Tuple)
                    and isinstance(n.value.elts[0], ast.Constant) and n.value.elts[0].value in ("problem", "info")):
                take(n.value.elts[1], top, top.name)
    elif isinstance(top, ast.FunctionDef) and top.name == "doctor":
        for n in ast.walk(top):
            if (isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "reason" for t in n.targets)
                    and not (isinstance(n.value, ast.Constant) and n.value.value is None)):
                take(n.value, top, top.name)
for t in templates:
    for frag in CONVERSION.split(t):
        frag = " ".join(frag.split())
        if len(frag) >= 8 and frag not in flat:
            problems.append("docs/troubleshooting.md lacks a finding doctor prints: [%s] (missing fragment: [%s])"
                            % (t, frag))
print(len(templates))
for p in problems:
    print(p)
EOF
found="$(python3 -I -B "$work/findings.py" "$repo_root/lib/host_identity.py" "$doc")" \
  || fail "the code-to-docs scan did not run: $found"
nfound="$(printf '%s\n' "$found" | sed -n 1p)"
# About 65 findings today: a scan that stops finding them fails here.
[ "$nfound" -ge 60 ] || fail "found only $nfound doctor findings in lib/host_identity.py (scan rot?)"
missing="$(printf '%s\n' "$found" | sed 1d)"
[ -z "$missing" ] || fail "$missing"

echo "PASS: troubleshooting_messages_test ($count messages, $checked fragments; $nfound doctor findings)"
