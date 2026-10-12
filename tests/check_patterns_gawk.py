# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""The check-patterns-gawk gate: bin/check-patterns under a character-counting awk.

bin/check-patterns measures Markdown line width with an awk that picks its
counting path by probing itself. macOS's awk counts bytes, so on the CI legs
the character-counting path would never run. gawk decodes UTF-8 under a UTF-8
locale, so this gate finds a locale in which it counts characters and runs
bin/check-patterns with CHECK_PATTERNS_AWK and CHECK_PATTERNS_AWK_LC_ALL set
to that gawk and that locale.

This file is the ONE place that decides. `make check-patterns-gawk` runs it,
the local-ci summary is that run's verdict line, and
tests/check_patterns_gawk_test.sh asks it for the locale with --locale, so the
gate, the summary and the test cannot pick differently.

Usage:
  check_patterns_gawk.py            run the gate; stdout is one verdict line
  check_patterns_gawk.py --locale   print the locale it would use, or nothing

STRICT (non-empty) turns a skip into exit 1, as everywhere in the Makefile.
PATH is trusted: `python3 -I` does not isolate it, and it picks the gawk.
Exit 0 on PASS or SKIP; 1 on a STRICT skip; else bin/check-patterns' own code.
"""

import os
import shutil
import subprocess
import sys

# The locales tried, in order: macOS ships en_US.UTF-8, many Linux images only
# C.UTF-8. A name is never trusted: gawk falls back to C, silently, under a
# locale the system does not have, so each is probed.
LOCALES = ("en_US.UTF-8", "C.UTF-8")

# An e acute, two bytes: 1 under a locale where gawk counts characters.
PROBE = 'BEGIN { print length("\\303\\251") }'


def probe_locale(gawk):
    """Return the first of LOCALES under which gawk counts characters, else None."""
    for loc in LOCALES:
        env = dict(os.environ, LC_ALL=loc)
        try:
            out = subprocess.run(
                [gawk, PROBE],
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=30,
                check=False,
            ).stdout
        except (OSError, subprocess.TimeoutExpired):
            continue
        if out.strip() == "1":
            return loc
    return None


def skip(reason, strict):
    if strict:
        print(f"ERROR: check-patterns-gawk: {reason} and STRICT=1 - failing closed", file=sys.stderr)
        return 1
    print(f"check-patterns-gawk: SKIP ({reason}; set STRICT=1 to fail, CI enforces it)")
    return 0


def main(argv):
    if argv not in ([], ["--locale"]):
        print("usage: check_patterns_gawk.py [--locale]", file=sys.stderr)
        return 2
    gawk = shutil.which("gawk")
    # which() returns a relative result for an empty or relative PATH element
    # (a bare "gawk" for an empty one). The probe would resolve it against this
    # directory, bin/check-patterns against the repo's, and a shell's `command
    # -v` can answer from a BASH_ENV hash entry instead: three lookups, three
    # possible binaries. An absolute path makes all of them the one probed.
    if gawk:
        gawk = os.path.abspath(gawk)
    loc = probe_locale(gawk) if gawk else None
    if argv == ["--locale"]:
        print(loc or "")
        return 0

    strict = bool(os.environ.get("STRICT"))
    if not gawk:
        return skip("gawk not installed", strict)
    if not loc:
        return skip(f"{gawk} counts bytes under {' and '.join(LOCALES)}", strict)

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    # The absolute path, so the gawk probed is the gawk bin/check-patterns runs.
    env = dict(os.environ, CHECK_PATTERNS_AWK=gawk, CHECK_PATTERNS_AWK_LC_ALL=loc)
    cmd = [os.path.join(repo, "bin", "check-patterns")]
    rc = subprocess.run(cmd, cwd=repo, env=env, check=False).returncode
    if rc != 0:
        print(
            f"ERROR: check-patterns-gawk: bin/check-patterns exited {rc} under {gawk}, LC_ALL={loc}",
            file=sys.stderr,
        )
        return rc
    print(f"check-patterns-gawk: PASS (bin/check-patterns under {gawk}, LC_ALL={loc})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
