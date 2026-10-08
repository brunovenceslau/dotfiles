# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# lib/host_identity.py - derive this host's git identity and SSH signing key
# from the host itself (its allowed-signers file and its ssh-agent), write them
# into ~/.config/git/config.local, rotate the key, and report a stale one.
#
# Called ONLY by install.sh, always as
# `python3 -I lib/host_identity.py --config-local PATH --installer PATH
#  --mode MODE ...`:
#   auto      the `install` and `link` arms (so every upgrade too): quiet when
#             the host already signs, one line when it cannot act, never
#             rotates, never writes user.name, never writes in an SSH session;
#             with --report-stale (the `link` arm) one line when the
#             configured key no longer verifies
#   identity  `install.sh identity`: write what is absent, then report a stale key
#   rotate    `install.sh identity --rotate`: replace ONLY user.signingkey
#   check     _signing_advisory: report a stale key or a shadowing signingkey
# `-I` keeps the current directory and PYTHON* variables out of sys.path, so a
# planted module beside the cwd cannot run. It is never linked onto PATH: lib/
# is not a tree the link engine walks. The behaviour (lookup order, matching
# rule, what is written) is documented once, in docs/shell-reference.md under
# "install.sh identity"; tests/host_identity_test.sh drives this file end to
# end through install.sh, and checks the parser against `ssh-keygen -Y verify`.
#
# Python, not bash: the allowed-signers options carry quoted values with
# spaces and commas, which bash 3.2 cannot parse robustly; not Go, because a
# fresh Mac has no Go toolchain while python3 ships with the Command Line Tools
# that git itself needs. Standard library only, and Python 3.9 safe (the CLT
# python3; tests/host_identity_test.sh parses this file with
# feature_version=(3, 9)), so no match statement and no `X | Y` type unions.
#
# Trust model: a key's COMMENT authenticates nothing, on either side, so a key
# is selected only by its exact `<type> <base64>` appearing both in the
# ssh-agent and in the allowed-signers file (an RSA key listed under
# rsa-sha2-256 or rsa-sha2-512 is the key ssh-rsa, as ssh-keygen reads it).
# Agent order never decides anything. The allowed-signers semantics are those
# of `ssh-keygen -Y verify` (OpenSSH sshsig.c, misc.c, match.c), which is what
# `git verify-commit` runs, including gpg.ssh.revocationFile;
# `ssh-keygen -Y find-principals` ignores namespaces and is NOT the reference.
# Where this file reads a line more strictly than ssh-keygen, it does so on
# purpose and the same way on every platform. Among those places: a seconds
# field of 61 and spaces inside a date field (leniencies of glibc's strptime()
# that macOS does not share), a repeated cert-authority, a NUL byte in a line
# that is not a comment (ssh-keygen reads a line only up to its first NUL),
# and key type names other than the canonical ones and rsa-sha2-256/512.
# Such an allowed-signers line is malformed here. A malformed line that spells
# an ssh-agent key anywhere, read as C reads it or word by word
# (keys_named()), makes the writing modes write nothing
# (Host.unclear_lines()), since ssh-keygen may read it as a valid entry for
# that key. In a flat revocation list, a line that is not a comment and is
# not a key, or holds a NUL byte, makes them write nothing as well.
# tests/host_identity_conformance.py holds this to
# ssh-keygen over fixed vectors and a generated corpus: no line ssh-keygen
# refuses is accepted, and no line it accepts is missed without being named.
#
# Exit status: 0 the identity is in place (written now or already there);
# 1 nothing could be decided, a value was left as it was, or a stale key was
# reported; 2 a usage error. `check` always exits 0.

import argparse
import base64
import binascii
import calendar
import errno
import hashlib
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import time
import unicodedata

PREFIX = "install: "

# Plain public key types and the number of SSH wire strings their blob holds
# (sshkey_from_blob). A blob must consist of exactly that many strings, the
# first naming the type, or the key is refused, as ssh-keygen refuses it.
# Certificate types are not accepted: a certificate is never this host's
# signing key, and its blob format is not checked here. ssh-dss is absent:
# OpenSSH 9.8 builds without DSA by default and 10.0 removed it, so a DSA line
# is one this step never selects.
KEY_TYPES = {
    "ssh-ed25519": 2,
    "ssh-rsa": 3,
    "ecdsa-sha2-nistp256": 3,
    "ecdsa-sha2-nistp384": 3,
    "ecdsa-sha2-nistp521": 3,
    "sk-ssh-ed25519@openssh.com": 3,
    "sk-ecdsa-sha2-nistp256@openssh.com": 4,
}
# Other names sshkey_type_from_name() gives a plain key type: the RSA
# signature algorithms name an RSA key as well, so `rsa-sha2-256 <blob>` is
# the key `ssh-rsa <blob>` to ssh-keygen. A key read under one of them is
# kept under its canonical name, the one ssh-add -L prints and the one
# written to user.signingkey.
TYPE_ALIASES = {"rsa-sha2-256": "ssh-rsa", "rsa-sha2-512": "ssh-rsa"}

# OpenSSH's WHITESPACE, which strdelimw() splits the principals field on;
# options and key fields end only at a space or a tab.
WS = " \t\r\n"
SPACE = " \t"
CERT_SUFFIX = "-cert-v01@openssh.com"
# A file larger than this is not an allowed-signers or revocation list.
MAX_FILE = 1 << 20
KRL_MAGIC = b"SSHKRL\n\0"
AGENT_TIMEOUT = 15

# git's repository-local environment, as `git rev-parse --local-env-vars`
# lists it (git 2.53), plus the GIT_CONFIG_KEY_<n>/VALUE_<n> pairs that
# GIT_CONFIG_COUNT numbers. Every git call here drops them: a git hook or a
# `git -c` in the caller's environment must not steer which trust root or
# identity this host gets. tests/host_identity_test.sh asserts this set still
# covers the running git's list. GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM and
# GIT_CONFIG_NOSYSTEM stay: they choose the user's own global and system
# files, which ARE the effective config this step reads (a GIT_CONFIG_GLOBAL
# that is not the XDG config makes the writing modes refuse, see main()).
GIT_LOCAL_ENV = frozenset(
    [
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_CONFIG",
        "GIT_CONFIG_PARAMETERS",
        "GIT_CONFIG_COUNT",
        "GIT_OBJECT_DIRECTORY",
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_IMPLICIT_WORK_TREE",
        "GIT_GRAFT_FILE",
        "GIT_INDEX_FILE",
        "GIT_NO_REPLACE_OBJECTS",
        "GIT_REPLACE_REF_BASE",
        "GIT_PREFIX",
        "GIT_SHALLOW_FILE",
        "GIT_COMMON_DIR",
    ]
)


# In auto mode warnings are collected here and reduced to one line (main()).
_captured = None


def log(msg):
    print(PREFIX + msg, flush=True)


def warn(msg):
    if _captured is not None:
        _captured.append(msg)
    else:
        print(PREFIX + msg, file=sys.stderr, flush=True)


def note(msg):
    """A warning worth showing on a direct run, never on an automatic one."""
    if _captured is None:
        warn(msg)


# --- allowed signers parsing (ssh-keygen(1), ALLOWED SIGNERS) ---------------


class Entry(object):
    def __init__(self, lineno, principals, options, key):
        self.lineno = lineno
        self.principals = principals  # the raw comma-separated pattern list
        self.options = options
        self.key = key


def _skip(s, i, chars):
    while i < len(s) and s[i] in chars:
        i += 1
    return i


def _strdelimw(s, i):
    """OpenSSH strdelimw() at s[i:]: (token, next) or (None, None).

    The token ends at the first WHITESPACE character. A double quote anywhere
    in it is dropped and opens a quoted run that ends the token at its
    closing quote. next is None when no delimiter follows (nothing after the
    token), which the caller treats as a line with no key.
    """
    j = i
    while j < len(s) and s[j] not in WS and s[j] != '"':
        j += 1
    if j == len(s):
        return s[i:], None
    if s[j] == '"':
        k = s.find('"', j + 1)
        if k < 0:
            return None, None
        return s[i:j] + s[j + 1 : k], _skip(s, k + 1, WS)
    return s[i:j], _skip(s, j + 1, WS)


def _advance_past_options(s, i):
    """OpenSSH sshkey_advance_past_options(): the end of the options field,
    or None for an unterminated quote. Only a space or a tab ends it."""
    quoted = False
    while i < len(s) and (quoted or s[i] not in SPACE):
        if s[i] == "\\" and i + 1 < len(s) and s[i + 1] == '"':
            i += 1
        elif s[i] == '"':
            quoted = not quoted
        i += 1
    if quoted and i == len(s):
        return None
    return i


def _dequote(s, i):
    """OpenSSH opt_dequote() at s[i:]: (value, next) or (None, None)."""
    if i >= len(s) or s[i] != '"':
        return None, None
    i += 1
    out = []
    while i < len(s) and s[i] != '"':
        if s[i] == "\\" and i + 1 < len(s) and s[i + 1] == '"':
            i += 1
        out.append(s[i])
        i += 1
    if i >= len(s):
        return None, None
    return "".join(out), i + 1


def _parse_options(opts):
    """OpenSSH sshsigopt_parse(); None means ssh-keygen rejects the line.

    Option names are case-insensitive, values must be quoted, a repeated
    option and an unknown one reject the line, and so does a validity time
    that does not parse or is the epoch itself. An EMPTY option (a leading
    comma, or two in a row) is skipped: sshsigopt_parse() has no "unknown
    option" branch of its own, so a position no name matches is accepted
    when it holds the comma, and rejected otherwise.
    """
    parsed = {}
    i = 0
    while i < len(opts):
        low = opts[i:].lower()
        name = None
        for candidate in ("namespaces", "valid-after", "valid-before"):
            if low.startswith(candidate + "="):
                name = candidate
        if low.startswith("cert-authority"):
            if "cert-authority" in parsed:
                return None
            parsed["cert-authority"] = True
            i += len("cert-authority")
        elif name is not None:
            if name in parsed:
                return None
            value, i = _dequote(opts, i + len(name) + 1)
            if value is None:
                return None
            if name != "namespaces":
                value = parse_ssh_time(value)
                if not value:
                    return None
            parsed[name] = value
        if i == len(opts):
            break
        if opts[i] != ",":
            return None
        i += 1
        if i == len(opts):
            return None
    return parsed


def key_blob(key):
    """The decoded SSH key blob of a (type, base64) pair."""
    return base64.b64decode(key[1].encode("ascii"), validate=True)


def _blob_ok(keytype, blob):
    """True when BLOB is exactly KEY_TYPES[keytype] SSH strings, the first
    naming keytype (sshkey_from_blob refuses trailing data)."""
    i = 0
    count = 0
    while i < len(blob):
        if i + 4 > len(blob):
            return False
        (n,) = struct.unpack(">I", blob[i : i + 4])
        if i + 4 + n > len(blob):
            return False
        if count == 0 and blob[4 : 4 + n] != keytype.encode("ascii"):
            return False
        i += 4 + n
        count += 1
    return count == KEY_TYPES[keytype] and (keytype != "ssh-ed25519" or len(blob) == 4 + 11 + 4 + 32)


def _read_key(s, i):
    """OpenSSH sshkey_read() at s[i:]: ((type, base64), next) or (None, i).

    Whitespace inside the blob field is skipped the way b64_pton() skips it,
    and the rest must be the canonical spelling of the decoded blob, as
    b64_pton() demands: spill bits set in the last character, or anything
    after the padding, refuse the key.
    """
    j = i
    while j < len(s) and s[j] not in SPACE:
        j += 1
    if j == len(s):
        return None, i
    keytype = TYPE_ALIASES.get(s[i:j], s[i:j])
    if keytype not in KEY_TYPES:
        return None, i
    j = _skip(s, j, SPACE)
    k = j
    while k < len(s) and s[k] not in SPACE:
        k += 1
    if k == j:
        return None, i
    b64 = "".join(c for c in s[j:k] if c not in " \t\n\v\f\r")
    try:
        blob = base64.b64decode(b64.encode("ascii"), validate=True)
    except (binascii.Error, ValueError, UnicodeEncodeError):
        return None, i
    if base64.b64encode(blob).decode("ascii") != b64 or not _blob_ok(keytype, blob):
        return None, i
    return (keytype, b64), k


def parse_key(s):
    """A `<type> <base64> [comment]` line (ssh-add -L, a .pub file, key::)."""
    key, _ = _read_key(s.strip(WS) + "\n", 0)
    return key


def fingerprint(key):
    """`SHA256:<base64, unpadded>`, the form ssh-keygen -l and git print."""
    digest = hashlib.sha256(key_blob(key)).digest()
    return "SHA256:" + base64.b64encode(digest).decode("ascii").rstrip("=")


def decode_lines(data):
    """Split bytes on \\n ONLY, as getline() does, and decode each line.

    str.splitlines() would also split on \\r, \\f, \\x1c-\\x1e, NEL and the
    Unicode separators, inventing lines ssh-keygen never sees. A line that is
    not valid UTF-8 keeps its bytes as surrogates: it still parses the way
    ssh-keygen parses it, and usable_principal() refuses any principal that
    carries one.
    """
    out = []
    for raw in data.split(b"\n"):
        try:
            out.append(raw.decode("utf-8"))
        except UnicodeDecodeError:
            out.append(raw.decode("utf-8", "surrogateescape"))
    return out


def keys_named(line):
    """Every public key LINE spells as `<type> <base64>` anywhere in it,
    whatever else the line holds, so a malformed line cannot hide a key that
    ssh-keygen would read in it. Two readings, unioned:

    - the way C reads the line: it ends at the first NUL (getline() keeps the
      byte, every string function then stops there), and sshkey_read() may
      start at any key type, glued to a quote or a carriage return or not;
      _read_key() skips the \\v, \\f and \\r b64_pton() skips in the blob;
    - every pair of whitespace-separated tokens, quotes read as spaces, over
      the whole line: it finds more than ssh-keygen would, which only ever
      makes the step write nothing.
    """
    found = set()
    c_line = line.split("\0", 1)[0] + "\n"
    for keytype in list(KEY_TYPES) + list(TYPE_ALIASES):
        start = c_line.find(keytype)
        while start >= 0:
            key, _ = _read_key(c_line, start)
            if key is not None:
                found.add(key)
            start = c_line.find(keytype, start + 1)
    tokens = line.replace('"', " ").split()
    for a, b in zip(tokens, tokens[1:]):
        key = parse_key(a + " " + b)
        if key is not None:
            found.add(key)
    return found


def parse_allowed_signers(data):
    """Return (entries, bad_line_numbers) for allowed-signers bytes (or str),
    following sshsig.c parse_principals_key_and_options()."""
    if isinstance(data, str):
        data = data.encode("utf-8", "surrogateescape")
    entries = []
    bad = []
    for lineno, line in enumerate(decode_lines(data), 1):
        line += "\n"
        i = _skip(line, 0, WS)
        if i == len(line) or line[i] == "#":
            continue
        # ssh-keygen reads the line only up to a NUL, so what follows one
        # is a different line to it: malformed here (see the header).
        if "\0" in line:
            bad.append(lineno)
            continue
        principals, i = _strdelimw(line, i)
        if principals is None or i is None:
            bad.append(lineno)
            continue
        options = {}
        key, _ = _read_key(line, i)
        if key is None:
            end = _advance_past_options(line, i)
            if end is None or end == len(line):
                bad.append(lineno)
                continue
            parsed = _parse_options(line[i:end])
            key, _ = _read_key(line, _skip(line, end + 1, SPACE))
            if parsed is None or key is None:
                bad.append(lineno)
                continue
            options = parsed
        entries.append(Entry(lineno, principals, options, key))
    return entries, bad


def match_pattern(value, pattern):
    """OpenSSH match_pattern(): `*` and `?` only; every other character,
    `[` and `]` included, is literal."""
    rx = "".join(".*" if c == "*" else "." if c == "?" else re.escape(c) for c in pattern)
    return re.fullmatch(rx, value, re.DOTALL) is not None


def match_pattern_list(value, patterns):
    """OpenSSH match_pattern_list() == 1: some sub-pattern matches and no
    `!negated` one does. A sub-pattern of 1023 characters or more fails the
    whole list, as OpenSSH's fixed buffer does."""
    matched = False
    for pat in patterns.split(","):
        negated = pat.startswith("!")
        if negated:
            pat = pat[1:]
        if len(pat) >= 1023:
            return False
        if match_pattern(value, pat):
            if negated:
                return False
            matched = True
    return matched


def parse_ssh_time(value):
    """OpenSSH parse_absolute_time() (misc.c): YYYYMMDD[HHMM[SS]], with an
    optional `Z` or `UTC` suffix in any case, to an epoch; None when
    ssh-keygen refuses it.

    Each field is range-checked the way strptime() checks it, never against
    its month, and then normalised the way timegm() and mktime() normalise it,
    so 20000230 is 1 March 2000. Without a suffix the time is local and read
    from a zeroed struct tm: tm_isdst = 0, standard time even on a summer
    date, never the DST guess Python's own conversions make. A time before
    the epoch, or one this platform cannot represent, is refused.
    tests/host_identity_conformance.py checks this against ssh-keygen in
    several time zones.
    """
    utc = False
    if len(value) > 1 and value[-1:].lower() == "z":
        utc, value = True, value[:-1]
    elif len(value) > 3 and value[-3:].lower() == "utc":
        utc, value = True, value[:-3]
    if len(value) not in (8, 12, 14) or any(c not in "0123456789" for c in value):
        return None
    fields = [int(value[i : i + 2]) for i in range(4, len(value), 2)] + [0, 0, 0]
    month, day, hour, minute, second = fields[:5]
    # %S is 0-60 on macOS; glibc's 61 is refused (see the header).
    if not (1 <= month <= 12 and 1 <= day <= 31 and hour <= 23 and minute <= 59 and second <= 60):
        return None
    tm = (int(value[:4]), month, day, hour, minute, second, 0, 0, 0)
    try:
        epoch = calendar.timegm(tm) if utc else time.mktime(tm)
    except (OverflowError, ValueError):
        return None
    return epoch if epoch >= 0 else None


def entry_usable_now(entry, now):
    """Valid for the git namespace at `now`, and not a certificate authority.

    Returns (usable, reason). A cert-authority line names a CA that signs
    certificates, never the user's own signing key, so it cannot be the
    identity.
    """
    opts = entry.options
    if opts.get("cert-authority"):
        return False, "cert-authority"
    ns = opts.get("namespaces")
    if ns is not None and not match_pattern_list("git", ns):
        return False, "outside the git namespace"
    if "valid-after" in opts and now < opts["valid-after"]:
        return False, "not yet valid"
    if "valid-before" in opts and now > opts["valid-before"]:
        return False, "expired"
    return True, ""


def entry_verifies(entry, principal, now):
    """What `ssh-keygen -Y verify -n git -I PRINCIPAL` decides for this line
    (before revocation, which is per key, not per line)."""
    ok, _ = entry_usable_now(entry, now)
    return ok and match_pattern_list(principal, entry.principals)


# Unicode categories never allowed in a value that lands in a git ident line:
# controls, invisible format characters, line and paragraph separators, and
# the surrogates that stand for bytes that were not UTF-8.
_BAD_CATEGORIES = frozenset(["Cc", "Cf", "Zl", "Zp", "Cs"])


def _clean(s):
    return not any(unicodedata.category(c) in _BAD_CATEGORIES for c in s)


def usable_principal(p):
    """A literal email address that is safe to write as user.email.

    allowed-signers principals are patterns (`*@example.com`), which can
    verify a signature but cannot be a committer address; `[` and `]` are
    literal to OpenSSH but refused here, so no principal reads as a pattern
    to a person either. Whitespace, `<>`, quotes and invisible characters are
    refused too: the value lands in a git ident line, `Name <email> date`,
    where they would forge or break its structure.
    """
    if not p or p.startswith("!") or any(c in p for c in '*?"\\<>[],'):
        return False
    if not _clean(p) or any(c.isspace() for c in p):
        return False
    local, at, domain = p.partition("@")
    return bool(at and local and domain and "@" not in domain)


def valid_name(n):
    """A user.name git can put in an ident line: no `<>`, no control,
    invisible or line-separator characters."""
    return bool(n) and _clean(n) and not any(c in "<>" for c in n)


# --- reading files and running tools -----------------------------------------


def read_small_file(path):
    """(bytes, None) or (None, reason) for a regular file of at most MAX_FILE.

    Opened non-blocking and checked with fstat, so a FIFO or a device named
    in the config never hangs or feeds the step.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError as e:
        return None, e.strerror
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None, "not a regular file"
        if st.st_size > MAX_FILE:
            return None, "larger than %d bytes" % MAX_FILE
        with os.fdopen(fd, "rb") as fh:
            fd = None
            return fh.read(MAX_FILE + 1), None
    except OSError as e:
        return None, e.strerror
    finally:
        if fd is not None:
            os.close(fd)


def git_env(ceiling):
    """The environment of every git call: the caller's, without git's
    repository-local variables (GIT_DIR among them), and with
    GIT_CEILING_DIRECTORIES set to CEILING alone, never appended to: an
    inherited list is the caller's, and an empty entry in it would stop git
    from resolving the entries after it."""
    env = dict(os.environ)
    for k in list(env):
        if k in GIT_LOCAL_ENV or k.startswith("GIT_CONFIG_KEY_") or k.startswith("GIT_CONFIG_VALUE_"):
            del env[k]
    env["GIT_CEILING_DIRECTORIES"] = ceiling
    return env


# Where every git call runs: (TemporaryDirectory, its path as getcwd() spells
# it, that path's parent), made once per process by git_isolate() and removed
# by git_release(). _git_refusal is why git cannot run outside a repository
# here, once git_isolate() has found a reason.
_git_place = None
_git_refusal = None


def _run_git(args, cwd, env):
    try:
        p = subprocess.run(
            ["git"] + args,
            cwd=cwd,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, "", str(e)
    out = p.stdout.decode("utf-8", "replace")
    out = out[:-1] if out.endswith("\n") else out
    return p.returncode, out, p.stderr.decode("utf-8", "replace").strip()


def _getcwd_in(path):
    """PATH as getcwd() spells it for a process started there. git compares
    exactly that string with its ceilings, and on a case-insensitive or
    normalizing file system (APFS) neither PATH nor realpath(PATH) need spell
    it the same way. Asked of a child, so this process's own working
    directory never changes."""
    p = subprocess.run(
        [sys.executable, "-I", "-S", "-c", "import os, sys; sys.stdout.buffer.write(os.getcwdb())"],
        cwd=path,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=30,
    )
    if p.returncode != 0 or not p.stdout.startswith(b"/"):
        raise OSError(errno.EIO, "no working directory reported")
    return os.fsdecode(p.stdout)


def _isolate():
    """None once git can run outside any repository, else the reason."""
    global _git_place
    for name in ("GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM"):
        value = os.environ.get(name)
        if value and not os.path.isabs(value):
            return "%s=%s is not an absolute path, so git would look for it where git runs" % (name, value)
    try:
        tmp = tempfile.TemporaryDirectory(prefix="host_identity.git.")
    except OSError as e:
        return "cannot make an empty directory for git: %s" % e
    _git_place = (tmp, None, None)  # from here on git_release() removes it
    try:
        cwd = _getcwd_in(tmp.name)
    except (OSError, subprocess.TimeoutExpired) as e:
        return "cannot read the working directory of %s: %s" % (tmp.name, e)
    ceiling = os.path.dirname(cwd)
    # ':' separates ceilings: a path holding one would be half-applied.
    if os.pathsep in ceiling:
        return "%s holds %r, which GIT_CEILING_DIRECTORIES cannot express" % (ceiling, os.pathsep)
    # Another user who can rename entries here could swap the empty
    # directory for one inside a repository after the check below.
    try:
        st = os.stat(ceiling)
    except OSError as e:
        return "cannot stat %s: %s" % (ceiling, e.strerror)
    if st.st_mode & stat.S_IWOTH and not st.st_mode & stat.S_ISVTX:
        return "%s is writable by every user and not sticky" % ceiling
    _git_place = (tmp, cwd, ceiling)
    # The proof, not the premise: git itself must find no repository from
    # there. In the C locale, so its message can be matched.
    env = git_env(ceiling)
    env["LC_ALL"] = "C"
    env.pop("LANGUAGE", None)
    rc, out, err = _run_git(["rev-parse", "--git-dir"], cwd, env)
    if rc == 0:
        return "git finds a repository (%s) from the empty directory %s" % (out, cwd)
    if "not a git repository" not in err:
        return "git rev-parse in %s did not report the absence of a repository: %s" % (cwd, err or "exit %d" % rc)
    return None


def git_isolate():
    """None when every git call here runs outside any repository, else the
    reason it cannot, which git() then returns as its error (rc 127) without
    running git.

    git runs from one fresh, empty temporary directory per process, and
    GIT_CEILING_DIRECTORIES names that directory's parent, so discovery looks
    at the empty directory alone and never climbs to the caller's
    repository, a $HOME that is one, or one holding $TMPDIR. Only the system
    and global levels are read. Not a GIT_DIR that cannot exist: git then
    dies on every read that evaluates an [includeIf "gitdir:..."] condition
    (rc 128, "Invalid path"). The parent is taken from the path getcwd()
    gives a process started there (_getcwd_in()), the string git itself
    compares with its ceilings, and git must then report that it finds no
    repository there (_isolate()). With the empty directory as git's working
    directory, a relative GIT_CONFIG_GLOBAL or GIT_CONFIG_SYSTEM would name a
    file inside it, so such a value is refused. Decided once, then
    remembered."""
    global _git_refusal
    if _git_place is None and _git_refusal is None:
        _git_refusal = _isolate()
    return _git_refusal


def git_release():
    """Remove the empty directory and forget the decision."""
    global _git_place, _git_refusal
    if _git_place is not None:
        try:
            _git_place[0].cleanup()
        except OSError:
            pass
    _git_place = _git_refusal = None


def git(args):
    """Run git outside any repository (git_isolate()); return (rc, stdout
    without the final newline, stderr)."""
    reason = git_isolate()
    if reason is not None:
        return 127, "", reason
    _, cwd, ceiling = _git_place
    return _run_git(args, cwd, git_env(ceiling))


class Value(object):
    """A config read: rc 0 is a value, 1 is unset, anything else an error."""

    def __init__(self, rc, text, err):
        self.rc = rc
        self.text = text
        self.err = err

    @property
    def set(self):
        return self.rc == 0

    @property
    def unset(self):
        return self.rc == 1

    @property
    def error(self):
        return self.rc not in (0, 1)


def same_file(a, b):
    try:
        return os.path.samefile(a, b)
    except OSError:
        return os.path.abspath(a) == os.path.abspath(b)


def _signingkey_source(value, home):
    """("literal", text) or ("path", absolute path) for a user.signingkey,
    by git's own rule (gpg-interface.c, is_literal_ssh_key()): a literal is
    `key::...` or starts with `ssh-`, and anything else is a path, so a bare
    `ecdsa-...` is a path to git. Never stripped: git sees the value byte for
    byte, so a quoted ` key::...` is a path to git (one that does not exist,
    so signing fails), and it is one here too. A relative path resolves
    against $HOME."""
    text = value
    if text.startswith("key::"):
        return "literal", text[len("key::"):]
    if text.startswith("ssh-"):
        return "literal", text
    return "path", os.path.join(home, os.path.expanduser(text))


def resolve_signingkey(value, home):
    """Return (key, needs_agent) for a user.signingkey value, or (None, None).

    A path to a PRIVATE key signs from the file (its `.pub` names the key); a
    literal or a path to a public key needs the ssh-agent to hold the private
    half.
    """
    kind, text = _signingkey_source(value, home)
    if kind == "literal":
        key = parse_key(text)
        return (key, True) if key else (None, None)
    data, _ = read_small_file(text)
    if data is None:
        return None, None
    content = data.decode("utf-8", "replace").strip()
    if content.startswith("-----BEGIN"):
        pub, _ = read_small_file(text + ".pub")
        key = parse_key(pub.decode("utf-8", "replace")) if pub is not None else None
        return (key, False) if key else (None, None)
    key = parse_key(content)
    return (key, True) if key else (None, None)


def signingkey_uncheckable(value, home):
    """True when user.signingkey is something git can sign with but this step
    cannot read as a plain public key: a certificate, or a private key with no
    usable `.pub` beside it. Such a value is reported as not checked, never
    as one that will fail."""
    kind, text = _signingkey_source(value, home)
    if kind == "path":
        data, _ = read_small_file(text)
        if data is None:
            return False
        text = data.decode("utf-8", "replace").strip()
        if text.startswith("-----BEGIN"):
            return True
    return (text.split(None, 1) or [""])[0].endswith(CERT_SUFFIX)


def load_revocation(path):
    """Read a gpg.ssh.revocationFile the way sshkey_check_revoked() does.

    Returns (frozenset of keys, None) for a flat list of public keys,
    (None, None) for a KRL (ask krl_revokes() per key), or (None, message)
    when the file cannot be used. In a flat list any non-comment line that
    is not a public key makes ssh-keygen fail every verification, so it
    fails closed here too. As in sshkey_in_file(), only spaces and tabs are
    skipped before a line is judged, so a line holding a lone carriage return
    is not blank: it fails, as it does for ssh-keygen.
    """
    data, why = read_small_file(path)
    if data is None:
        return None, "identity: cannot read gpg.ssh.revocationFile %s: %s - writing nothing" % (path, why)
    if data.startswith(KRL_MAGIC):
        return None, None
    keys = set()
    for n, line in enumerate(decode_lines(data), 1):
        stripped = line.lstrip(SPACE)
        if not stripped or stripped.startswith("#"):
            continue
        if "\0" in line:
            # ssh-keygen reads such a line only up to the NUL; what it then
            # revokes is not this step's to guess (see the header).
            return None, ("identity: gpg.ssh.revocationFile %s line %d holds a NUL byte - writing nothing"
                          % (path, n))
        key, _ = _read_key(stripped + "\n", 0)
        if key is None:
            return None, ("identity: gpg.ssh.revocationFile %s line %d is not a public key - writing nothing"
                          % (path, n))
        keys.add(key)
    return frozenset(keys), None


def krl_revokes(path, key):
    """`ssh-keygen -Q` against a KRL: True revoked, False not, None unknown
    (an unwritable TMPDIR included: that is a refusal, never a traceback)."""
    pub = None
    try:
        fd, pub = tempfile.mkstemp(prefix="host_identity.", suffix=".pub")
        with os.fdopen(fd, "w") as fh:
            fh.write("%s %s\n" % key)
        p = subprocess.run(
            ["ssh-keygen", "-Q", "-f", path, pub],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    finally:
        if pub is not None:
            try:
                os.unlink(pub)
            except OSError:
                pass
    return {0: False, 1: True}.get(p.returncode)


class Host(object):
    """What this host says, read once per run: its effective git config (no
    repository level), its allowed-signers and revocation files, and its
    ssh-agent keys."""

    def __init__(self, home, config_local, installer):
        self.home = home
        self.config_local = config_local
        self.installer = installer
        self.now = time.time()
        self._signers = None
        self._bad_keys = []
        self._agent = None
        self._revocation = None
        self._revoked_plain = None
        self._revoked = {}

    def effective(self, key, typ=None):
        """The value a commit outside any repository would see: every level
        combined, includes on. Not --global, which reads ONE file (and skips
        the XDG config, where config.local is included, when ~/.gitconfig
        exists)."""
        args = ["config", "--includes"]
        if typ:
            args.append("--type=" + typ)
        rc, out, err = git(args + ["--get", key])
        return Value(rc, out, err)

    def origins(self, key):
        """[(origin, value)] for every effective value of KEY, in git's order;
        [] when it is unset or cannot be read (origins_or_error())."""
        return self.origins_or_error(key)[0]

    def origins_or_error(self, key):
        """(origins, None), or ([], git's error) when git fails to read."""
        rc, out, err = git(["config", "--includes", "--show-origin", "--null", "--get-all", key])
        if rc == 1:
            return [], None
        if rc != 0:
            return [], err or "git exited %d" % rc
        parts = out.split("\0")
        return [(parts[i], parts[i + 1]) for i in range(0, len(parts) - 1, 2)], None

    def in_local(self, key, typ=None):
        if not os.path.lexists(self.config_local):
            return Value(1, "", "")
        args = ["config", "--file", self.config_local]
        if typ:
            args.append("--type=" + typ)
        rc, out, err = git(args + ["--get", key])
        return Value(rc, out, err)

    def is_local_origin(self, origin):
        return origin.startswith("file:") and same_file(origin[len("file:"):], self.config_local)

    def includes_local(self):
        """(True, None) when some file git reads has an [include] path that
        resolves to config.local, so a value written there is read; (False,
        git's error) when the includes cannot be read. includeIf is not
        counted: these reads run outside any repository (git_isolate()),
        where a gitdir: or onbranch: condition never holds, and leaving out a
        hasconfig: one can only make the writing modes write nothing."""
        origins, err = self.origins_or_error("include.path")
        for origin, value in origins:
            if not origin.startswith("file:") or not value:
                continue
            base = os.path.dirname(origin[len("file:"):])
            path = os.path.join(base, os.path.expanduser(value))
            if same_file(path, self.config_local):
                return True, None
        return False, err

    def locate_signers(self):
        """Return (path, source, error_message).

        Order: $CANGA_HOST_ALLOWED_SIGNERS, then the effective
        gpg.ssh.allowedSignersFile, then $XDG_CONFIG_HOME/git/allowed_signers
        when it exists. A source that is SET but names a missing file is
        reported as such, never skipped for the next one: the operator
        pointed there. A relative path resolves against $HOME here.
        """
        env = os.environ.get("CANGA_HOST_ALLOWED_SIGNERS", "")
        if env:
            return os.path.join(self.home, os.path.expanduser(env)), "CANGA_HOST_ALLOWED_SIGNERS", None
        # --type=path makes git expand a leading ~ the way git itself does
        # when it verifies.
        v = self.effective("gpg.ssh.allowedSignersFile", typ="path")
        if v.set and v.text:
            return os.path.join(self.home, os.path.expanduser(v.text)), "gpg.ssh.allowedSignersFile", None
        if v.error:
            return None, None, "identity: could not read gpg.ssh.allowedSignersFile (%s) - writing nothing" % v.err
        xdg = os.environ.get("XDG_CONFIG_HOME", "")
        if not xdg or not os.path.isabs(xdg):
            xdg = os.path.join(self.home, ".config")
        default = os.path.join(xdg, "git", "allowed_signers")
        if os.path.lexists(default):
            return default, "the default path", None
        return None, None, None

    def signers(self):
        """(path, source, entries) or (None, None, message-lines) once."""
        if self._signers is None:
            self._signers = self._read_signers()
        return self._signers

    def _read_signers(self):
        path, source, err = self.locate_signers()
        if path is None:
            if err:
                return None, None, [err]
            return None, None, [
                "identity: no allowed-signers file found - writing nothing",
                "identity:   set CANGA_HOST_ALLOWED_SIGNERS or gpg.ssh.allowedSignersFile, or",
                "identity:   create ~/.config/git/allowed_signers (one `<email> <keytype> <key>` per line)",
            ]
        data, why = read_small_file(path)
        if data is None:
            return None, None, [
                "identity: cannot read the allowed-signers file %s (from %s): %s - writing nothing"
                % (path, source, why)
            ]
        entries, bad = parse_allowed_signers(data)
        lines = decode_lines(data)
        self._bad_keys = [(n, keys_named(lines[n - 1])) for n in bad]
        if bad:
            note("identity: skipped malformed allowed-signers line(s) %s in %s"
                 % (", ".join(str(n) for n in bad), path))
        return path, source, entries

    def unclear_lines(self, keys):
        """Malformed allowed-signers line numbers that name one of KEYS.

        This step reads some lines more strictly than ssh-keygen does on
        every platform (see the header), so a malformed line naming an agent
        key may be a valid entry to the ssh-keygen that verifies: which key
        is this host's is then ambiguous."""
        self.signers()
        return [n for n, named in self._bad_keys if named & keys]

    def revocation(self):
        """(path, None) when no file or a readable one is configured, or
        (path, message) when gpg.ssh.revocationFile is set but unusable."""
        if self._revocation is None:
            self._revocation = self._read_revocation()
        return self._revocation

    def _read_revocation(self):
        v = self.effective("gpg.ssh.revocationFile", typ="path")
        if v.error:
            return None, "identity: could not read gpg.ssh.revocationFile (%s) - writing nothing" % v.err
        if not v.set or not v.text:
            self._revoked_plain = frozenset()
            return None, None
        path = os.path.join(self.home, os.path.expanduser(v.text))
        self._revoked_plain, err = load_revocation(path)
        return path, err

    def is_revoked(self, key):
        """True, False, or None when the revocation file cannot answer."""
        path, err = self.revocation()
        if err:
            return None
        if self._revoked_plain is not None:
            return key in self._revoked_plain
        if key not in self._revoked:
            self._revoked[key] = krl_revokes(path, key)
        return self._revoked[key]

    def agent(self):
        """(set of (type, b64), None) or (None, message) from `ssh-add -L`, once.

        The message is the whole warning line, so docs/troubleshooting.md can
        quote it verbatim (tests/troubleshooting_messages_test.sh).
        """
        if self._agent is None:
            self._agent = self._read_agent()
        return self._agent

    def _read_agent(self):
        try:
            p = subprocess.run(
                ["ssh-add", "-L"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=AGENT_TIMEOUT,
            )
        except OSError:
            return None, "identity: ssh-add was not found on PATH - writing nothing"
        except subprocess.TimeoutExpired:
            return None, "identity: ssh-add -L did not answer within %d seconds - writing nothing" % AGENT_TIMEOUT
        if p.returncode == 1:
            return None, "identity: the ssh-agent holds no keys - writing nothing"
        if p.returncode != 0:
            return None, "identity: cannot reach an ssh-agent (ssh-add -L exited %d) - writing nothing" % p.returncode
        keys = set()
        for line in decode_lines(p.stdout):
            key = parse_key(line)
            if key is not None:
                keys.add(key)
        if not keys:
            return None, "identity: the ssh-agent holds no keys - writing nothing"
        return keys, None

    def candidates(self, entries, keys):
        """{(principal, key)}: every agent key that `ssh-keygen -Y verify`
        would accept for a literal principal its line names, and that is not
        revoked."""
        pairs = set()
        for e in entries:
            if e.key not in keys or self.is_revoked(e.key) is not False:
                continue
            for p in e.principals.split(","):
                if usable_principal(p) and entry_verifies(e, p, self.now):
                    pairs.add((p, e.key))
        return pairs

    def why_no_candidate(self, entries, keys, path, email=None):
        """The headline when the agent keys ENTRIES list were all dropped by
        gpg.ssh.revocationFile (revoked, or ssh-keygen -Q could not tell), or
        None when the cause is the entries themselves. With EMAIL, ENTRIES
        are that email's lines and the headline says so: the claim is about
        those keys only."""
        states = set(self.is_revoked(k) for k in set(e.key for e in entries if e.key in keys))
        if not states or False in states:
            return None
        # Whole literals: docs/troubleshooting.md quotes them verbatim.
        rev_path, _ = self.revocation()
        where = "in " + path if email is None else "for %s in %s" % (email, path)
        if None in states:
            msg = "identity: ssh-keygen -Q could not check the ssh-agent key(s) listed %s against gpg.ssh.revocationFile %s - writing nothing"
            return msg % (where, rev_path)
        msg = "identity: every ssh-agent key listed %s is revoked by gpg.ssh.revocationFile %s - writing nothing"
        return msg % (where, rev_path)

    def why_invalid(self, entries, key, email):
        """Why KEY does not verify for EMAIL, or None when it does."""
        revoked = self.is_revoked(key)
        if revoked is None:
            return "the revocation file cannot be checked"
        if revoked:
            return "revoked by gpg.ssh.revocationFile"
        reasons = []
        for e in entries:
            if e.key != key or not match_pattern_list(email, e.principals):
                continue
            ok, why = entry_usable_now(e, self.now)
            if ok:
                return None
            reasons.append("line %d: %s" % (e.lineno, why))
        return "; ".join(reasons) or "not listed for " + email


# --- writing config.local ---------------------------------------------------


def _copy_fd(src_fd, dst_path):
    with os.fdopen(os.dup(src_fd), "rb") as src, open(dst_path, "wb") as out:
        src.seek(0)
        shutil.copyfileobj(src, out)


def backup_once(path, src_fd, mode):
    """Copy the open config.local (SRC_FD) to PATH.bak unless a .bak exists.

    The first .bak is the pristine pre-framework copy and the one worth
    keeping (lib/link.sh, _link_backup), so an existing one is never
    replaced. A hard link of a finished temp file publishes it atomically
    and refuses an existing name; where hard links are not supported, an
    O_CREAT|O_EXCL create keeps the same no-clobber.
    """
    bak = path + ".bak"
    if os.path.lexists(bak):
        log("identity: keeping the existing backup %s" % bak)
        return
    fd, tmp = tempfile.mkstemp(prefix=".config.local.bak.", dir=os.path.dirname(path))
    os.close(fd)
    try:
        _copy_fd(src_fd, tmp)
        os.chmod(tmp, mode)
        try:
            os.link(tmp, bak)
        except OSError as e:
            if e.errno == errno.EEXIST:
                raise
            out = os.open(bak, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
            with os.fdopen(out, "wb") as dst, open(tmp, "rb") as src:
                shutil.copyfileobj(src, dst)
    finally:
        os.unlink(tmp)
    log("identity: backed up %s -> %s" % (path, bak))


def write_keys(path, items):
    """Set ITEMS ((key, value), ...) in PATH atomically, keeping the rest.

    A mktemp sibling + rename, as _write_git_local_config in lib/link.sh does,
    so a failure never leaves a half-written config; `git config --file` does
    the quoting. The current file is opened with O_NOFOLLOW and checked with
    fstat, so what is copied and backed up is the regular file that was
    checked: a symlinked config.local is the operator's arrangement, and the
    rename would replace the link with a plain file, so it is refused.
    """
    d = os.path.dirname(path)
    src = None
    try:
        try:
            src = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except OSError as e:
            if e.errno == errno.ELOOP:
                warn("identity: refusing to write through the symlink %s - add the keys by hand" % path)
                return False
            if e.errno != errno.ENOENT:
                warn("identity: cannot open %s: %s" % (path, e.strerror))
                return False
        if src is not None and not stat.S_ISREG(os.fstat(src).st_mode):
            warn("identity: %s is not a regular file - writing nothing" % path)
            return False
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".config.local.", dir=d)
        os.close(fd)
    except OSError as e:
        warn("identity: cannot stage a write next to %s: %s" % (path, e.strerror))
        if src is not None:
            os.close(src)
        return False
    try:
        if src is not None:
            mode = stat.S_IMODE(os.fstat(src).st_mode)
            _copy_fd(src, tmp)
            os.chmod(tmp, mode)
        for key, value in items:
            rc, _, err = git(["config", "--file", tmp, key, value])
            if rc != 0:
                warn("identity: git config could not set %s: %s" % (key, err))
                return False
        if src is not None:
            backup_once(path, src, mode)
        os.replace(tmp, path)
        tmp = None
    except OSError as e:
        warn("identity: cannot write %s: %s" % (path, e.strerror))
        return False
    finally:
        if src is not None:
            os.close(src)
        if tmp is not None and os.path.lexists(tmp):
            os.unlink(tmp)
    return True


# --- the flows --------------------------------------------------------------


def hint_rerun(host):
    warn("identity:   then run: %s identity [--name \"Full Name\"]" % host.installer)


def require_ssh_format(host):
    """git signs with ssh-keygen only under gpg.format = ssh, which the tracked
    config sets. Anything else means a key:: value would go to gpg (every
    commit then fails closed), or the framework config is not included."""
    v = host.effective("gpg.format")
    if v.set and v.text == "ssh":
        return True
    if v.error:
        warn("identity: cannot read gpg.format (%s) - writing nothing" % v.err)
        return False
    warn("identity: gpg.format is %s, not ssh - writing nothing"
         % (repr(v.text) if v.set else "unset"))
    warn("identity:   see \"Framework git settings do not apply\" in docs/troubleshooting.md")
    return False


def refuse_unclear(host, keys, path):
    """True, having said why, when a malformed line names an agent key."""
    unclear = host.unclear_lines(keys)
    if not unclear:
        return False
    nums = ", ".join(str(n) for n in unclear)
    warn("identity: malformed allowed-signers line(s) %s in %s name an ssh-agent key - writing nothing" % (nums, path))
    warn("identity:   ssh-keygen may read such a line differently; fix or remove it, then re-run")
    return True


def require_revocation(host):
    path, err = host.revocation()
    if err:
        warn(err)
        return False
    return True


def select(host, pairs, email):
    """D2: narrow (principal, key) pairs to one identity, or explain why not.

    The expected email is the effective user.email when set; otherwise the
    one principal every candidate shares. More than one distinct key left for
    that email writes nothing: agent order and comments never break a tie.
    Returns ((email, key), None) or (None, [message lines]).
    """
    principals = sorted(set(p for p, _ in pairs))
    if email:
        pairs = set(pk for pk in pairs if pk[0] == email)
        if not pairs:
            lines = ["identity: no ssh-agent key is listed for user.email %s - writing nothing" % email]
            lines += ["identity:   listed for this agent instead: " + p for p in principals]
            return None, lines
    elif len(principals) > 1:
        lines = ["identity: more than one identity matches the ssh-agent keys - writing nothing"]
        for p, k in sorted(pairs):
            lines.append("identity:   %s %s" % (p, fingerprint(k)))
        lines.append("identity:   set the one this host commits as first, then re-run:")
        lines.append("identity:   git config --file %s user.email <email>" % host.config_local)
        return None, lines
    keys = sorted(set(k for _, k in pairs))
    email = email or principals[0]
    if len(keys) > 1:
        lines = ["identity: more than one ssh-agent key is listed for %s - writing nothing" % email]
        lines += ["identity:   key %s" % fingerprint(k) for k in keys]
        lines.append("identity:   keep only this host's signing key in the agent (ssh-add -d), or retire")
        lines.append("identity:   the other entry in the allowed-signers file, then re-run")
        return None, lines
    return (email, keys[0]), None


def last_origin(host, key):
    """The origin git reads KEY from last (the one that wins), or a stand-in."""
    origins = host.origins(key)
    return origins[-1][0] if origins else "another level"


def overridden_signing(host):
    """`commit.gpgsign` / `tag.gpgsign` that config.local sets true while
    another level makes them false: [(key, origin)]. Not the host's exception
    (that is a false config.local does not contradict): signing is off
    against what config.local says."""
    out = []
    for key in ("commit.gpgsign", "tag.gpgsign"):
        local = host.in_local(key, "bool")
        eff = host.effective(key, "bool")
        if local.set and local.text == "true" and eff.set and eff.text == "false":
            out.append((key, last_origin(host, key)))
    return out


def already_configured(host):
    """user.email, user.signingkey and commit.gpgsign are all set, the last
    true or false: an explicit false that is the host's exception (kept by
    identity()), or one overriding a true in config.local, which is not an
    exception and which `auto --report-stale` reports (overridden_line())."""
    email = host.effective("user.email")
    key = host.effective("user.signingkey")
    sign = host.effective("commit.gpgsign", typ="bool")
    return email.set and key.set and sign.set


def equal_value(host, key, current, want, sigkey):
    """Whether a config value already says what the step would write."""
    if key == "user.signingkey":
        return resolve_signingkey(current, host.home)[0] == sigkey
    if key == "gpg.ssh.allowedSignersFile":
        return same_file(os.path.join(host.home, os.path.expanduser(current)), want)
    return current == want


def identity(host, name):
    """Write what is absent; never replace a value. Returns an exit status."""
    if not require_ssh_format(host) or not require_revocation(host):
        return 1
    path, source, entries = host.signers()
    if path is None:
        for line in entries:
            warn(line)
        hint_rerun(host)
        return 1
    keys, why = host.agent()
    if keys is None:
        warn(why)
        warn("identity:   load this host's signing key with ssh-add, then run:")
        warn("identity:   %s identity [--name \"Full Name\"]" % host.installer)
        return 1
    if refuse_unclear(host, keys, path):
        return 1
    pairs = host.candidates(entries, keys)
    if not pairs:
        revoked = host.why_no_candidate(entries, keys, path)
        if revoked:
            warn(revoked)
            warn("identity:   load a key that is not revoked, list it in the allowed-signers file,")
            hint_rerun(host)
            return 1
        warn("identity: no ssh-agent key is listed for the git namespace in %s - writing nothing" % path)
        warn("identity:   add `<email> <keytype> <key>` for this host's signing key there,")
        hint_rerun(host)
        return 1
    email_v = host.effective("user.email")
    if email_v.error:
        warn("identity: cannot read user.email (%s) - writing nothing" % email_v.err)
        return 1
    if email_v.set and not any(p == email_v.text for p, _ in pairs):
        # Name the cause when the revocation file is what removed this
        # email's keys, rather than calling them unlisted.
        mine = [e for e in entries if match_pattern_list(email_v.text, e.principals)]
        revoked = host.why_no_candidate(mine, keys, path, email_v.text)
        if revoked:
            warn(revoked)
            warn("identity:   load a key for %s that is not revoked, then re-run" % email_v.text)
            return 1
    chosen, lines = select(host, pairs, email_v.text if email_v.set else "")
    if chosen is None:
        for line in lines:
            warn(line)
        return 1
    email, sigkey = chosen

    desired = []
    if name is not None:
        desired.append(("user.name", name, None))
    desired += [
        ("user.email", email, None),
        ("user.signingkey", "key::%s %s" % sigkey, None),
        ("commit.gpgsign", "true", "bool"),
        ("tag.gpgsign", "true", "bool"),
    ]
    # So a git that does not inherit this shell's environment (a GUI client)
    # verifies against the same trust root. A value set at some level is the
    # operator's, even when the environment pointed this step elsewhere: that
    # disagreement is reported, not fixed.
    if source != "gpg.ssh.allowedSignersFile":
        cur = host.effective("gpg.ssh.allowedSignersFile", typ="path")
        if cur.unset:
            desired.append(("gpg.ssh.allowedSignersFile", path, None))
        elif cur.set and not same_file(os.path.join(host.home, os.path.expanduser(cur.text)), path):
            warn("identity: CANGA_HOST_ALLOWED_SIGNERS (%s) differs from gpg.ssh.allowedSignersFile (%s),"
                 % (path, cur.text))
            warn("identity:   which git verifies with")

    to_write = []
    conflicts = 0
    # The exception lines: printed at once on a direct run; in the automatic
    # step only when it then writes, so a refusal stays one line.
    kept = []
    for key, want, typ in desired:
        local = host.in_local(key, typ)
        eff = host.effective(key, typ)
        bad = [v for v in (local, eff) if v.error]
        if bad:
            warn("identity: cannot read %s (%s) - leaving it" % (key, bad[0].err))
            conflicts += 1
            continue
        if typ == "bool" and eff.set and eff.text == "false" and not (local.set and local.text == "true"):
            # An effective false that config.local does not contradict is this
            # host's exception to signing (an operator decision): kept, and not
            # a conflict, so the email and the key are still written. A true
            # in config.local that another level overrides is NOT one: it is
            # reported as overridden below.
            kept.append("identity: %s is false (%s) - kept as this host's exception, so it stays off"
                        % (key, last_origin(host, key)))
            continue
        if typ == "bool" and local.set and local.text == "false" and eff.set and eff.text == "true":
            # The reverse: config.local says false, a later level says true and
            # wins. Nothing to write; the effective value is what signs.
            kept.append("identity: %s is false in %s, but %s sets it true and wins"
                        % (key, host.config_local, last_origin(host, key)))
            continue
        if local.set and equal_value(host, key, local.text, want, sigkey):
            # Right in config.local, but another level may still win: the
            # value a commit sees is the effective one.
            if eff.set and not equal_value(host, key, eff.text, want, sigkey):
                warn("identity: %s is overridden by %s - leaving it: %s" % (key, last_origin(host, key), eff.text))
                conflicts += 1
            continue
        cur = local if local.set else eff
        if not cur.set:
            to_write.append((key, want, typ))
        elif not equal_value(host, key, cur.text, want, sigkey):
            warn("identity: %s is already set to a different value - leaving it: %s" % (key, cur.text))
            conflicts += 1

    if _captured is None:
        for line in kept:
            log(line)
    if conflicts:
        # Nothing at all next to a conflict: commit.gpgsign = true beside a
        # signing key this step did not choose could sign with a key that
        # does not verify, or make every commit fail.
        warn("identity:   writing nothing; fix the value(s) above, or keep them on purpose")
        return 1
    if to_write:
        # Prove git reads config.local BEFORE writing to it: a file nothing
        # includes is written but never read.
        included, err = host.includes_local()
        if err is not None:
            warn("identity: cannot read include.path (%s) - writing nothing" % err)
            return 1
        if not included:
            warn("identity: git does not read %s (no [include] reaches it) - writing nothing" % host.config_local)
            warn("identity:   see \"Framework git settings do not apply\" in docs/troubleshooting.md")
            return 1
        if not write_keys(host.config_local, [(k, v) for k, v, _ in to_write]):
            return 1
        log("identity: wrote %s to %s" % (", ".join(k for k, _, _ in to_write), host.config_local))
        if _captured is not None:
            for line in kept:
                log(line)
        # Read every written key back through the effective config: a later
        # file can still override what was just written.
        for key, want, typ in to_write:
            back = host.effective(key, typ)
            if not back.set or not equal_value(host, key, back.text, want, sigkey):
                origins = host.origins(key)
                origin = origins[-1][0] if origins else "nowhere"
                warn("identity: %s reads %s from %s after the write, not the value written"
                     % (key, repr(back.text) if back.set else "unset", origin))
                conflicts += 1
    elif not conflicts:
        log("identity: already configured for %s (%s)" % (email, fingerprint(sigkey)))

    if conflicts:
        return 1
    if host.effective("user.name").unset:
        warn("identity: user.name is not set - run: %s identity --name \"Full Name\"" % host.installer)
    return 0


def rotate(host):
    """Replace ONLY user.signingkey, and only when the configured key no longer
    verifies for user.email and exactly one agent key does."""
    if not require_ssh_format(host) or not require_revocation(host):
        return 1
    email_v = host.effective("user.email")
    if email_v.error:
        warn("identity: cannot read user.email (%s) - writing nothing" % email_v.err)
        return 1
    if not email_v.set:
        warn("identity: --rotate needs user.email - run %s identity first" % host.installer)
        return 1
    email = email_v.text
    origins = host.origins("user.signingkey")
    if not origins:
        warn("identity: --rotate: user.signingkey is not set - nothing to rotate; run %s identity" % host.installer)
        return 1
    origin, old_value = origins[-1]
    if not host.is_local_origin(origin):
        warn("identity: --rotate: user.signingkey comes from %s, not %s - edit it there"
             % (origin, host.config_local))
        return 1
    old, _ = resolve_signingkey(old_value, host.home)
    if old is None:
        warn("identity: --rotate: user.signingkey (%s) names no readable public key - refusing" % old_value)
        return 1
    path, _, entries = host.signers()
    if path is None:
        for line in entries:
            warn(line)
        return 1
    why = host.why_invalid(entries, old, email)
    if why is None:
        warn("identity: --rotate: %s is still valid for %s in %s - nothing to rotate"
             % (fingerprint(old), email, path))
        return 1
    keys, err = host.agent()
    if keys is None:
        warn(err)
        return 1
    if refuse_unclear(host, keys, path):
        return 1
    new = sorted(set(k for p, k in host.candidates(entries, keys) if p == email))
    if len(new) != 1:
        warn("identity: --rotate: %d ssh-agent keys are valid for %s in %s - refusing"
             % (len(new), email, path))
        for k in new:
            warn("identity:   key %s" % fingerprint(k))
        return 1
    new = new[0]
    value = "key::%s %s" % new
    if not write_keys(host.config_local, [("user.signingkey", value)]):
        return 1
    log("identity: rotated user.signingkey for %s: %s -> %s (old key: %s)"
        % (email, fingerprint(old), fingerprint(new), why))
    log("identity:   it was: %s" % old_value)
    back = host.effective("user.signingkey")
    if not back.set or resolve_signingkey(back.text, host.home)[0] != new:
        warn("identity: user.signingkey reads %s after the write, not the new key" % repr(back.text))
        return 1
    return 0


def stale_reason(host, key):
    """(email, path, why) when KEY no longer verifies for the effective
    user.email in the allowed-signers file, or None when it does or when
    there is nothing to judge it by (no user.email, no file)."""
    email_v = host.effective("user.email")
    path, _, entries = host.signers()
    if path is None or not email_v.set:
        return None
    why = host.why_invalid(entries, key, email_v.text)
    return None if why is None else (email_v.text, path, why)


def check_signing_key(host):
    """Report an effective user.signingkey that will not work, or that comes
    from outside config.local. Returns True when something was reported."""
    fmt = host.effective("gpg.format")
    if fmt.error:
        warn("identity: cannot read gpg.format (%s) - user.signingkey not checked" % fmt.err)
        return True
    if fmt.text != "ssh":
        return False  # a GPG key id is not ours to judge
    origins = host.origins("user.signingkey")
    if not origins:
        return False
    reported = False
    outside = [o for o, _ in origins if not host.is_local_origin(o)]
    for origin in outside:
        tail = " - the last one git reads wins" if len(origins) > 1 else ""
        warn("identity: user.signingkey is set in %s, outside %s%s" % (origin, host.config_local, tail))
        reported = True
    value = origins[-1][1]
    key, needs_agent = resolve_signingkey(value, host.home)
    if key is None and signingkey_uncheckable(value, host.home):
        warn("identity: user.signingkey (%s) is a certificate or a private key without its .pub - not checked"
             % value)
        return reported
    if key is None:
        warn("identity: user.signingkey (%s) names no readable SSH public key - signing will fail" % value)
        return True
    _, rev_err = host.revocation()
    stale = None if rev_err else stale_reason(host, key)
    if rev_err:
        warn(rev_err.replace(" - writing nothing", ""))
        reported = True
    elif stale is not None:
        warn("identity: user.signingkey %s is not valid for %s in %s (%s)"
             % ((fingerprint(key),) + stale))
        warn("identity:   new signatures will not verify; run: %s identity --rotate" % host.installer)
        reported = True
    if needs_agent:
        keys, _ = host.agent()
        if keys is None or key not in keys:
            warn("identity: user.signingkey %s is not loaded in the ssh-agent - signing will fail"
                 % fingerprint(key))
            warn("identity:   ssh-add this host's signing key (ssh-add -L lists what the agent holds)")
            reported = True
    return reported


def overridden_line(host):
    """`auto --report-stale`: ONE line when config.local turns signing on and
    a later level turns it off again; quiet otherwise."""
    found = overridden_signing(host)
    if not found:
        return 0
    what = "; ".join("%s = false from %s" % kv for kv in found)
    warn("identity: signing is off against %s: %s - see %s identity" % (host.config_local, what, host.installer))
    return 1


def stale_line(host):
    """`auto --report-stale` on a configured host (the `link` arm, so every
    upgrade): ONE line when the configured key no longer verifies for
    user.email (retired, expired, revoked, or the revocation file cannot be
    checked), quiet otherwise and on anything it cannot judge. Read only, so
    it runs in an SSH session too. `install` leaves this to the fuller
    report of _signing_advisory."""
    if host.effective("gpg.format").text != "ssh":
        return 0
    origins = host.origins("user.signingkey")
    key = resolve_signingkey(origins[-1][1], host.home)[0] if origins else None
    stale = stale_reason(host, key) if key is not None else None
    if stale is None:
        return 0
    email, path, why = stale
    # --rotate refuses while the revocation file cannot be checked, so that
    # case points at the details instead.
    if host.is_revoked(key) is None:
        msg = "identity: user.signingkey %s is not valid for %s in %s (%s) - see %s identity"
    else:
        msg = "identity: user.signingkey %s is not valid for %s in %s (%s) - run %s identity --rotate"
    warn(msg % (fingerprint(key), email, path, why, host.installer))
    return 1


def auto(host):
    """The automatic step on a host that does not sign yet: one line when it
    cannot act."""
    # Over SSH the agent is usually forwarded from ANOTHER machine, whose
    # keys are not this host's to sign with. One literal: docs/troubleshooting.md
    # quotes it verbatim.
    if os.environ.get("SSH_CONNECTION"):
        msg = "identity: not set automatically in an SSH session (a forwarded agent holds another machine's keys) - run %s identity to set it on purpose"
        warn(msg % host.installer)
        return 1
    return identity(host, None)


def global_reads_local(host):
    """False, with the reason, when GIT_CONFIG_GLOBAL names a file other than
    the XDG config (the upgrade's vgit uses /dev/null per command): it hides
    config.local, which that file includes, so every key would read as
    absent. Only writing needs this; reads report what git itself sees."""
    glob = os.environ.get("GIT_CONFIG_GLOBAL")
    xdg_config = os.path.join(os.path.dirname(host.config_local), "config")
    if glob is None or same_file(glob, xdg_config):
        return True
    warn("identity: GIT_CONFIG_GLOBAL=%s is not %s, so git would not read %s - writing nothing"
         % (glob, xdg_config, host.config_local))
    return False


def local_is_regular(host):
    """False, with the reason, when config.local exists and is not a regular
    file. Checked before any git read: git opens it through the include, and
    a FIFO there would hold every read to its 30 s timeout."""
    try:
        st = os.stat(host.config_local)
    except OSError:
        return True  # absent, or unreachable: write_keys() reports that
    if stat.S_ISREG(st.st_mode):
        return True
    warn("identity: %s is not a regular file - writing nothing" % host.config_local)
    return False


def run(host, mode, name, report_stale):
    """Dispatch one mode; returns its exit status."""
    if not local_is_regular(host):
        return 0 if mode == "check" else 1
    # Before any git read, so a mode never acts on reads that only failed.
    reason = git_isolate()
    if reason is not None:
        warn("identity: not reading the git config: %s" % reason)
        return 0 if mode == "check" else 1
    if mode == "check":
        check_signing_key(host)
        # identity() reports these itself, as conflicts; only check says it here.
        for key, origin in overridden_signing(host):
            warn("identity: %s is true in %s, but %s sets it false and wins - signing stays off"
                 % (key, host.config_local, origin))
        return 0
    if mode == "auto" and already_configured(host):
        if not report_stale:
            return 0
        # One line at most: main() keeps only the first warning.
        return overridden_line(host) or stale_line(host)
    if not global_reads_local(host):
        return 1
    if mode == "rotate":
        return rotate(host)
    if mode == "auto":
        return auto(host)
    rc = identity(host, name)
    return 1 if check_signing_key(host) else rc


def headline(lines):
    """The first warning that states a cause (hint lines are indented)."""
    for line in lines:
        if not line.startswith("identity:   "):
            return line
    return lines[0] if lines else ""


def main(argv):
    global _captured
    ap = argparse.ArgumentParser(prog="install.sh identity", add_help=False)
    ap.add_argument("--config-local", required=True)
    ap.add_argument("--installer", default="./install.sh")
    ap.add_argument("--mode", choices=("auto", "identity", "rotate", "check"), required=True)
    ap.add_argument("--name")
    ap.add_argument("--report-stale", action="store_true")
    args = ap.parse_args(argv)
    if args.report_stale and args.mode != "auto":
        warn("identity: --report-stale is taken only by --mode auto")
        return 2
    if args.name is not None:
        n = args.name.strip()
        if not valid_name(n):
            warn("identity: --name needs a non-empty value on one line, without < or >")
            return 2
        args.name = n
        if args.mode != "identity":
            warn("identity: --name is taken only by install.sh identity, without --rotate")
            return 2
    if not os.path.isabs(args.config_local):
        warn("identity: --config-local must be an absolute path")
        return 2
    home = os.environ.get("HOME", "")
    if not home or not os.path.isabs(home):
        warn("identity: HOME is not an absolute path - skipping")
        return 1
    host = Host(home, args.config_local, args.installer)
    if args.mode == "auto":
        _captured = []
    try:
        rc = run(host, args.mode, args.name, args.report_stale)
    finally:
        git_release()
        lines, _captured = _captured, None
    if lines:
        if rc == 0:
            for line in lines:
                warn(line)
        else:
            line = headline(lines)
            if "%s identity" % host.installer not in line:
                line += " (details: %s identity)" % host.installer
            warn(line)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
