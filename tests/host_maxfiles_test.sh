#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Tests for `install.sh maxfiles` and lib/host_maxfiles.py, with no privilege
# on any platform: nothing here runs sudo, and on macOS only the read-only
# `--status` mode reaches the host. The decisions (what runs, in what order,
# what is skipped) are tests/host_maxfiles_units.py, with the commands
# replaced; this suite runs it, renders the plist into a scratch directory and
# reads it back, lints it with plutil where macOS has one, and drives the
# install.sh arm's option handling.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
module="$repo_root/lib/host_maxfiles.py"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0; ok() { pass=$((pass + 1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/host_maxfiles_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

command -v python3 >/dev/null 2>&1 && python3 -I -c '' 2>/dev/null \
  || fail "python3 does not run here; this suite needs it"

# --- The CLT python3 is 3.9: both files must parse as 3.9.
for f in "$module" "$repo_root/tests/host_maxfiles_units.py"; do
  python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), feature_version=(3, 9))' "$f" \
    && ok || fail "$f does not parse as Python 3.9"
done

# --- The decisions, with run() and read_state() replaced.
units="$(python3 -I -B "$repo_root/tests/host_maxfiles_units.py" "$module" 2>&1)" \
  || fail "the units crashed: $units"
! grep -q '^BAD' <<<"$units" && ok || fail "units: $(grep '^BAD' <<<"$units")"
[ "$(grep -c '^ok' <<<"$units")" = 46 ] && ok || fail "test bug: the units did not all run: $units"

# --- The plist, rendered into a scratch directory and read back.
plist="$(python3 -I -B "$module" --mode render --out "$work")" || fail "render failed"
[ "$plist" = "$work/local.limits.maxfiles.plist" ] && [ -s "$plist" ] && ok \
  || fail "render must write local.limits.maxfiles.plist into --out: $plist"
python3 -I - "$plist" "$module" <<'PY' && ok || fail "the rendered plist does not hold the expected daemon"
import importlib.util, plistlib, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[2])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
with open(sys.argv[1], "rb") as f:
    pl = plistlib.load(f)
n = m.MAXFILES
assert pl["Label"] == "local.limits.maxfiles", pl
assert pl["RunAtLoad"] is True, pl
assert pl["ProgramArguments"] == ["/bin/sh", "-c",
    "/usr/sbin/sysctl -w kern.maxfiles=%d kern.maxfilesperproc=%d && /bin/launchctl limit maxfiles %d %d"
    % (n, n, n, n)], pl
PY
if [ -x /usr/bin/plutil ]; then
  /usr/bin/plutil -lint "$plist" >/dev/null && ok || fail "plutil -lint rejects the rendered plist"
else
  echo "SKIP: plutil -lint of the rendered plist (no /usr/bin/plutil: not macOS)"
fi

# --- The install.sh arm. install.sh refuses root, so as root only the module
# itself was tested above.
if [ "$(/usr/bin/id -u 2>/dev/null || echo 0)" = 0 ]; then
  echo "SKIP: the install.sh maxfiles arm (running as root: install.sh refuses root)"
else
  run() { rc=0; out="$("$repo_root/install.sh" "$@" 2>&1)" || rc=$?; }
  run maxfiles --bogus
  [ "$rc" = 2 ] && grep -q 'maxfiles: unknown option: --bogus' <<<"$out" && ok \
    || fail "an unknown maxfiles option must exit 2 and name it (rc $rc): $out"
  run maxfiles --status --uninstall
  [ "$rc" = 2 ] && grep -q 'one option at most' <<<"$out" && ok \
    || fail "two maxfiles options must exit 2 (rc $rc): $out"
  run help
  grep -q '|maxfiles \[--uninstall|--status\]\]' <<<"$out" && ok \
    || fail "the usage line must name maxfiles and its options: $out"
  if [ "$(uname -s)" = Darwin ]; then
    # Read only: the CI runner has no daemon, so 1 is expected, 0 if one is there.
    run maxfiles --status
    { [ "$rc" = 0 ] || [ "$rc" = 1 ]; } && grep -q '^maxfiles: want [0-9]*; have kern.maxfiles [0-9]' <<<"$out" && ok \
      || fail "maxfiles --status must report the measured limits (rc $rc): $out"
  else
    for opt in "" --uninstall --status; do
      # shellcheck disable=SC2086  # an empty $opt must vanish
      run maxfiles $opt
      [ "$rc" = 0 ] && grep -q '^maxfiles: macOS only' <<<"$out" && ok \
        || fail "maxfiles $opt must do nothing off macOS and say why (rc $rc): $out"
    done
  fi
fi

echo "PASS: host_maxfiles_test ($pass assertions)"
