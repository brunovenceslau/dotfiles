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
#             the host already signs and has a user.name, one line when it
#             cannot act, one line naming `identity --name` while only
#             user.name is missing, never rotates, never writes user.name
#             (the operator's to choose; the line only suggests the
#             account's full name), never writes in an SSH session,
#             silent on a host that opted out of signing (a false in
#             config.local, opted_out());
#             with --report-stale (the `link` arm) one line when the
#             configured key no longer verifies
#   identity  `install.sh identity`: write what is absent, then report a stale key
#   rotate    `install.sh identity --rotate`: replace ONLY user.signingkey
#   check     _signing_advisory (advisory()): an unsigned host, a ~/.gitconfig,
#             a stale key or a shadowing signingkey; silent on signing for a
#             host that opted out
#   doctor    `install.sh doctor [--verbose]`: read only; print each problem
#             in one line (every check with --verbose), exit 1 on a problem
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
# and key type names other than those in KEY_TYPES and rsa-sha2-256/512.
# Such an allowed-signers line is malformed here. A malformed line that spells
# an ssh-agent key anywhere, read as C reads it or word by word
# (keys_named()), makes the writing modes write nothing
# (Host.unclear_lines()), since ssh-keygen may read it as a valid entry for
# that key. In a flat revocation list, a line that is not blank, not a
# comment and not a key, or holds a NUL byte, makes them write nothing as
# well.
# tests/host_identity_conformance.py holds this to
# ssh-keygen over fixed vectors and a generated corpus: no line ssh-keygen
# refuses is accepted, and no line it accepts is missed without being named.
#
# Exit status: 0 the identity is in place (written now or already there);
# 1 nothing could be decided, a value was left as it was, or a stale key was
# reported; 2 a usage error. `check` always exits 0. `doctor` exits 0 when it
# found no problem (an explicitly opted-out host included), 1 when it did.

import argparse
import base64
import binascii
import calendar
import errno
import hashlib
import os
import platform
import pwd
import re
import shlex
import shutil
import signal
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


def escape(s):
    """One printable line: a backslash doubles, and a character that is not
    printable (a control, LF, CR, a bidi or zero-width format character, a
    byte that was not UTF-8) prints as its escape, so a value cannot forge a
    second line, rewrite the terminal or hide part of the message. The same
    rule as .githooks/commit_identity.py's escape(), kept beside it rather
    than imported: each file runs alone."""
    out = []
    for ch in s:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif 0xDC80 <= o <= 0xDCFF:
            out.append("\\x%02x" % (o - 0xDC00))
        elif ch.isprintable():
            out.append(ch)
        elif o <= 0xFF:
            out.append("\\x%02x" % o)
        elif o <= 0xFFFF:
            out.append("\\u%04x" % o)
        else:
            out.append("\\U%08x" % o)
    return "".join(out)


def quoted(s):
    """S escaped and in single quotes, a quote inside it spelled \\x27, so
    the value cannot close its quotes and read as message text. The
    backslash escape() doubles keeps \\x27 from being read back as one."""
    return "'%s'" % escape(s).replace("'", "\\x27")


def _shown(value):
    """VALUE (a config value, an origin, a path, a tool's message) as a
    message prints it: bare when escape() leaves it as it is and it neither
    is empty nor starts or ends with a space (which would print as nothing,
    or blur into the words around it), else quoted(). Applied to each
    interpolated value at its call site, never to a whole line: the line's
    literal text is what docs/troubleshooting.md quotes, and it must print as
    written.

    Unlike .githooks/commit_identity.py, which quotes every value, a plain
    value stays bare here: docs/troubleshooting.md, docs/signing-key.md and
    tests/host_identity_test.sh hold the bare shapes of these lines, and the
    property this guards is that no value can act on the terminal or pass
    for message text, which the quotes of an unusual value already give.
    tests/host_identity_units.py checks statically that every value put into
    a string goes through an escaper."""
    value = str(value)
    if value and value == value.strip() and escape(value) == value:
        return value
    return quoted(value)


def shell_word(path):
    """PATH as one word of a command a message tells the operator to run
    (the installer, config.local): shlex.quote(), so a space or a `$` in it
    stays one literal word and the command runs as printed. A path that
    _shown() leaves bare is quoted only when a shell needs it, so the
    quoted messages keep their shape. One that escape() changes (a control
    character, a backslash) prints escaped inside the quotes: it can never
    reach the terminal raw, and the command then names its escaped
    spelling, a path no shell would turn back into the real one."""
    return shlex.quote(escape(path))


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


def gecos_name(pw):
    """The full name git itself would take from the account PW (a pwd
    entry), as its ident.c does: the GECOS field up to its first comma, each
    `&` replaced by the login with its first letter capitalized. Empty when
    the account has none (a Linux account's GECOS often is)."""
    field = (pw.pw_gecos or "").split(",", 1)[0]
    login = pw.pw_name or ""
    # git capitalizes with an ASCII toupper(); str.upper() differs from it
    # only when the login's first letter is not ASCII, which a login never
    # is in practice. Either way the result is only a suggestion.
    return field.replace("&", login[:1].upper() + login[1:]).strip()


# Characters that a shell still interprets inside double quotes (`!` in an
# interactive bash or zsh): a name holding one is not suggested, since the
# suggested command would not pass it through unchanged.
_SHELL_ACTIVE = '"\\$`!'

# Code points a terminal shows as nothing or as a plain space that
# _BAD_CATEGORIES lets through (they are letters, marks or symbols, not
# format characters): the Hangul fillers, the combining grapheme joiner,
# the Khmer and Mongolian invisible vowels and selectors, the variation
# selectors, the braille blank, the Egyptian hieroglyph blanks and the
# Khitan small script filler. A suggested name holding one would look like
# a different name than the one written.
_INVISIBLE = ((0x034F, 0x034F), (0x115F, 0x1160), (0x17B4, 0x17B5), (0x180B, 0x180F),
              (0x2800, 0x2800), (0x3164, 0x3164), (0xFE00, 0xFE0F), (0xFFA0, 0xFFA0),
              (0x13441, 0x13442), (0x16FE4, 0x16FE4), (0xE0100, 0xE01EF))
# Unassigned (Cn) and private-use (Co) code points have no agreed glyph, so
# a suggestion holding one may render as another name. Only the suggestion
# refuses them: valid_name(), which decides what is written, does not, and
# an older Python's Unicode table only makes the placeholder more likely.
_UNSHOWN_CATEGORIES = frozenset(["Cn", "Co"])


def _invisible(c):
    o = ord(c)
    return any(lo <= o <= hi for lo, hi in _INVISIBLE)


def suggested_name(name):
    """The value the missing-name line puts after --name: NAME when
    install.sh identity would accept it, a shell passes it through double
    quotes unchanged, and it reads on screen as what it is (a letter or a
    digit, no space but U+0020, no invisible, unassigned or private-use
    code point), else the placeholder. missing_name_line() puts it in
    through _shown() as well, so a control character could never reach the
    terminal even if valid_name() were loosened."""
    if (name and valid_name(name)
            and not any(c in _SHELL_ACTIVE for c in name)
            and any(c.isalnum() for c in name)
            and not any(c.isspace() and c != " " for c in name)
            and not any(_invisible(c) for c in name)
            and not any(unicodedata.category(c) in _UNSHOWN_CATEGORIES for c in name)):
        return name
    return "Full Name"


def account_name():
    """gecos_name() of the account running this, or "" when it has none."""
    try:
        return gecos_name(pwd.getpwuid(os.getuid()))
    except (KeyError, OSError):
        return ""


def missing_name_line(host):
    """ONE literal, quoted by docs/signing-key.md: the hint for a host with no
    user.name. The step never writes the name itself (only --name does): it
    is the operator's to choose, so the account's full name is a
    suggestion."""
    return 'identity: user.name is not set - run: %s identity --name "%s"' % (
        shell_word(host.installer), _shown(suggested_name(account_name())))


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
    from resolving the entries after it. Without GIT_TRACE* too, and with
    the trace2 targets set to 0: a trace sent to stderr would come before the
    line _isolate() matches, and trace2.*Target in a config file turns one on
    unless the environment says otherwise."""
    env = dict(os.environ)
    for k in list(env):
        if (k in GIT_LOCAL_ENV or k.startswith("GIT_CONFIG_KEY_") or k.startswith("GIT_CONFIG_VALUE_")
                or k.startswith("GIT_TRACE")):
            del env[k]
    for k in ("GIT_TRACE2", "GIT_TRACE2_EVENT", "GIT_TRACE2_PERF"):
        env[k] = "0"
    env["GIT_CEILING_DIRECTORIES"] = ceiling
    return env


# GitPlace.refusal before git_isolate() has decided anything.
UNDECIDED = "git has not been proven to run outside a repository"


class GitPlace(object):
    """Where every git call of this process runs, decided once by
    git_isolate() and undone by git_release().

    made     the empty directory, recorded as soon as it exists, so
             git_release() removes it whatever happens after
    cwd      that directory as getcwd() spells it, set only once git has
             been proven to find no repository from there
    refusal  why git cannot run outside a repository here: UNDECIDED until
             git_isolate() decides, None once it is proven

    git() runs git only when refusal is None."""

    def __init__(self):
        self.made = None
        self.cwd = None
        self.refusal = UNDECIDED

    @property
    def ceiling(self):
        """The one GIT_CEILING_DIRECTORIES entry: cwd's parent."""
        return os.path.dirname(self.cwd)


_git_place = None


class Refusal(Exception):
    """A reason git cannot run outside a repository here, raised where it
    is found and returned by _isolate()."""


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


# Opens the current directory for fchdir() without reading it: O_PATH
# (Linux) needs search permission only, so an execute-only directory is a
# place to return to. macOS has no O_PATH, and O_RDONLY needs read
# permission; there the way back is the path getcwd() names instead.
_BACK_FLAGS = getattr(os, "O_PATH", os.O_RDONLY) | getattr(os, "O_DIRECTORY", 0)


def _getcwd_in(path):
    """PATH as getcwd() spells it from inside. git compares exactly that
    string with its ceilings, and on a case-insensitive or normalizing file
    system (APFS) neither PATH nor realpath(PATH) need spell it the same way.
    This process steps in and back out: through a descriptor when it can
    open its current directory, else by the path getcwd() gives for it.
    Raises Refusal when it finds no way back (before stepping anywhere) or
    cannot take the one it found."""
    back, back_path = None, None
    try:
        back = os.open(".", _BACK_FLAGS)
    except OSError as e:
        try:
            back_path = os.getcwd()
        except OSError:
            raise Refusal("cannot open the current directory to return to it (%s)" % _shown(e))
    try:
        os.chdir(path)
        return os.getcwd()
    finally:
        try:
            if back is not None:
                os.fchdir(back)
            else:
                os.chdir(back_path)
        except OSError as e:
            # This process stays in the empty directory, which
            # git_release() then removes: its working directory may be gone.
            raise Refusal("cannot return to the current directory (%s)" % _shown(e))
        finally:
            if back is not None:
                os.close(back)


def _isolate(place):
    """None once git is proven to run outside any repository from PLACE,
    else the reason it cannot."""
    for env_name in ("GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM"):
        value = os.environ.get(env_name)
        if value and not os.path.isabs(value):
            return "%s=%s is not an absolute path, so git would look for it where git runs" % (env_name, _shown(value))
    try:
        place.made = tempfile.mkdtemp(prefix="host_identity.git.")
        cwd = _getcwd_in(place.made)
    except Refusal as e:
        return str(e)
    except OSError as e:
        return "cannot make an empty directory for git and enter it: %s" % _shown(e)
    ceiling = os.path.dirname(cwd)
    # ':' separates ceilings: a path holding one would be half-applied.
    if os.pathsep in ceiling:
        return "%s holds %r, which GIT_CEILING_DIRECTORIES cannot express" % (_shown(ceiling), os.pathsep)
    # Anyone who can rename entries here could swap the empty directory for
    # one inside a repository. Only the plain case is refused; the rest is a
    # deferred decision (docs/architecture.md, "Deferred decisions").
    try:
        st = os.stat(ceiling)
    except OSError as e:
        return "cannot stat %s: %s" % (_shown(ceiling), e.strerror)
    if st.st_mode & stat.S_IWOTH and not st.st_mode & stat.S_ISVTX:
        return "%s is writable by every user and not sticky" % _shown(ceiling)
    # The proof, not the premise: git itself must find no repository from
    # there. In the C locale, so its first line can be matched exactly; any
    # other failure (a config file git cannot parse, a repository it refuses
    # as dubiously owned) means git cannot start here at all.
    env = git_env(ceiling)
    env["LC_ALL"] = "C"
    env.pop("LANGUAGE", None)
    rc, out, err = _run_git(["rev-parse", "--git-dir"], cwd, env)
    if rc == 0:
        return "git finds a repository (%s) from the empty directory %s" % (_shown(out), _shown(cwd))
    if not err.startswith("fatal: not a git repository"):
        return "git cannot start (%s)" % (_shown(err) if err else "exit %d" % rc)
    place.cwd = cwd
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
    gives inside the directory (_getcwd_in()), the string git itself
    compares with its ceilings, and git must then report that it finds no
    repository there (_isolate()). With the empty directory as git's working
    directory, a relative GIT_CONFIG_GLOBAL or GIT_CONFIG_SYSTEM would name a
    file inside it, so such a value is refused. Decided once, then
    remembered; an interrupted decision is a refusal."""
    global _git_place
    if _git_place is None:
        _git_place = GitPlace()
        try:
            _git_place.refusal = _isolate(_git_place)
        except BaseException:
            _git_place.refusal = "the check that git runs outside any repository was interrupted"
            raise
    return _git_place.refusal


def git_release():
    """Remove the empty directory and forget the decision. Explicit, not a
    finalizer's: the directory is gone when this returns."""
    global _git_place
    if _git_place is not None and _git_place.made is not None:
        shutil.rmtree(_git_place.made, ignore_errors=True)
    _git_place = None


def git(args):
    """Run git outside any repository (git_isolate()); return (rc, stdout
    without the final newline, stderr)."""
    reason = git_isolate()
    if reason is not None:
        return 127, "", reason
    return _run_git(args, _git_place.cwd, git_env(_git_place.ceiling))


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
        return None, "identity: cannot read gpg.ssh.revocationFile %s: %s - writing nothing" % (_shown(path), why)
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
                          % (_shown(path), n))
        key, _ = _read_key(stripped + "\n", 0)
        if key is None:
            return None, ("identity: gpg.ssh.revocationFile %s line %d is not a public key - writing nothing"
                          % (_shown(path), n))
        keys.add(key)
    return frozenset(keys), None


class _Held(object):
    """A block during which the signals entry() unwinds on (SIGINT, SIGTERM,
    SIGHUP) wait: one that arrives is delivered when the block ends. Wraps
    the creation of a temporary file AND the assignment that records it, so
    no signal can unwind between the two and leave a file nobody removes."""

    SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)

    def __enter__(self):
        self.old = signal.pthread_sigmask(signal.SIG_BLOCK, self.SIGNALS)

    def __exit__(self, *exc):
        signal.pthread_sigmask(signal.SIG_SETMASK, self.old)
        return False


def krl_revokes(path, key):
    """`ssh-keygen -Q` against a KRL: True revoked, False not, None unknown
    (an unwritable TMPDIR included: that is a refusal, never a traceback).
    The key goes to ssh-keygen in a temporary file, removed by the finally
    below on every way out: a return, an error, ^C, and a SIGTERM or SIGHUP
    (entry() turns those into an exception, Terminated)."""
    pub = None
    try:
        with _Held():
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
            return None, None, "identity: could not read gpg.ssh.allowedSignersFile (%s) - writing nothing" % _shown(v.err)
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
                % (_shown(path), source, why)
            ]
        entries, bad = parse_allowed_signers(data)
        lines = decode_lines(data)
        self._bad_keys = [(n, keys_named(lines[n - 1])) for n in bad]
        if bad:
            note("identity: skipped malformed allowed-signers line(s) %s in %s"
                 % (", ".join(str(n) for n in bad), _shown(path)))
        return path, source, entries

    def malformed_lines(self):
        """The line numbers of the allowed-signers file this step skipped as
        malformed (see the header)."""
        self.signers()
        return [n for n, _ in self._bad_keys]

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
            return None, "identity: could not read gpg.ssh.revocationFile (%s) - writing nothing" % _shown(v.err)
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
        why = "in " + _shown(path) if email is None else "for %s in %s" % (_shown(email), _shown(path))
        if None in states:
            msg = "identity: ssh-keygen -Q could not check the ssh-agent key(s) listed %s against gpg.ssh.revocationFile %s - writing nothing"
            return msg % (why, _shown(rev_path))
        msg = "identity: every ssh-agent key listed %s is revoked by gpg.ssh.revocationFile %s - writing nothing"
        return msg % (why, _shown(rev_path))

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
        return "; ".join(reasons) or "not listed for " + _shown(email)


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
        log("identity: keeping the existing backup %s" % _shown(bak))
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
    log("identity: backed up %s -> %s" % (_shown(path), _shown(bak)))


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
                warn("identity: refusing to write through the symlink %s - add the keys by hand" % _shown(path))
                return False
            if e.errno != errno.ENOENT:
                warn("identity: cannot open %s: %s" % (_shown(path), e.strerror))
                return False
        if src is not None and not stat.S_ISREG(os.fstat(src).st_mode):
            warn("identity: %s is not a regular file - writing nothing" % _shown(path))
            return False
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".config.local.", dir=d)
        os.close(fd)
    except OSError as e:
        warn("identity: cannot stage a write next to %s: %s" % (_shown(path), e.strerror))
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
                warn("identity: git config could not set %s: %s" % (key, _shown(err)))
                return False
        if src is not None:
            backup_once(path, src, mode)
        os.replace(tmp, path)
        tmp = None
    except OSError as e:
        warn("identity: cannot write %s: %s" % (_shown(path), e.strerror))
        return False
    finally:
        if src is not None:
            os.close(src)
        if tmp is not None and os.path.lexists(tmp):
            os.unlink(tmp)
    return True


# --- the flows --------------------------------------------------------------


def hint_rerun(host):
    warn("identity:   then run: %s identity [--name \"Full Name\"]" % shell_word(host.installer))


def require_ssh_format(host):
    """git signs with ssh-keygen only under gpg.format = ssh, which the tracked
    config sets. Anything else means a key:: value would go to gpg (every
    commit then fails closed), or the framework config is not included."""
    v = host.effective("gpg.format")
    if v.set and v.text == "ssh":
        return True
    if v.error:
        warn("identity: cannot read gpg.format (%s) - writing nothing" % _shown(v.err))
        return False
    warn("identity: gpg.format is %s, not ssh - writing nothing"
         % (quoted(v.text) if v.set else "unset"))
    warn("identity:   see \"Framework git settings do not apply\" in docs/troubleshooting.md")
    return False


def refuse_unclear(host, keys, path):
    """True, having said why, when a malformed line names an agent key."""
    unclear = host.unclear_lines(keys)
    if not unclear:
        return False
    nums = ", ".join(str(n) for n in unclear)
    warn("identity: malformed allowed-signers line(s) %s in %s name an ssh-agent key - writing nothing" % (nums, _shown(path)))
    warn("identity:   ssh-keygen may read such a line differently; fix or remove it, then re-run")
    return True


def require_revocation(host):
    path, said = host.revocation()
    if said:
        warn(said)
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
            lines = ["identity: no ssh-agent key is listed for user.email %s - writing nothing" % _shown(email)]
            lines += ["identity:   listed for this agent instead: " + _shown(p) for p in principals]
            return None, lines
    elif len(principals) > 1:
        lines = ["identity: more than one identity matches the ssh-agent keys - writing nothing"]
        for p, k in sorted(pairs):
            lines.append("identity:   %s %s" % (_shown(p), fingerprint(k)))
        lines.append("identity:   set the one this host commits as first, then re-run:")
        lines.append("identity:   git config --file %s user.email <email>" % shell_word(host.config_local))
        return None, lines
    keys = sorted(set(k for _, k in pairs))
    email = email or principals[0]
    if len(keys) > 1:
        lines = ["identity: more than one ssh-agent key is listed for %s - writing nothing" % _shown(email)]
        lines += ["identity:   key %s" % fingerprint(k) for k in keys]
        lines.append("identity:   keep only this host's signing key in the agent (ssh-add -d), or retire")
        lines.append("identity:   the other entry in the allowed-signers file, then re-run")
        return None, lines
    return (email, keys[0]), None


def last_origin(host, key):
    """The origin git reads KEY from last (the one that wins), or a stand-in.
    Only ever names a file in a message, so a read error gets the stand-in
    too."""
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


def opted_out(host):
    """The origin (config.local) of the commit.gpgsign = false that opts this
    host out of signing, or None.

    ONLY a false that git reads last from config.local itself opts out: that
    file is this host's own, written on purpose. A false from any other level
    (/etc/gitconfig, ~/.gitconfig, a file an [include] pulls in) may be
    nobody's decision for this host, so it must never silence the step: it
    stays the host's exception, which identity() writes beside and reports,
    and which doctor reports as a problem (Doctor.values()). A true in
    config.local that a later level turns false is an override, reported by
    overridden_line(). While tag.gpgsign is effectively true the host still
    signs tags, so the signing checks still matter: not an opt-out either."""
    eff = host.effective("commit.gpgsign", "bool")
    if not (eff.set and eff.text == "false"):
        return None
    origin = last_origin(host, "commit.gpgsign")
    if not host.is_local_origin(origin):
        return None
    tag = host.effective("tag.gpgsign", "bool")
    if tag.set and tag.text == "true":
        return None
    return origin


def signing_configured(host):
    """user.email, user.signingkey and commit.gpgsign are all set, the last
    true or false. A false is the host's exception (identity() kept it) or
    one overriding a true in config.local, which `auto --report-stale`
    reports (overridden_line()); the opted-out host never gets this far
    (run())."""
    email = host.effective("user.email")
    key = host.effective("user.signingkey")
    sign = host.effective("commit.gpgsign", typ="bool")
    return email.set and key.set and sign.set


def already_configured(host):
    """signing_configured(), and user.name is set too: the tracked
    user.useConfigOnly = true makes git refuse every commit without it."""
    return signing_configured(host) and host.effective("user.name").set


def commits_fail_closed(host):
    """True when git refuses every commit on this host: commit.gpgsign is
    effectively true (the tracked config sets it) under gpg.format = ssh,
    and neither user.signingkey nor gpg.ssh.defaultKeyCommand is set, so
    git dies with `either user.signingkey or gpg.ssh.defaultKeyCommand needs
    to be configured`. False on anything it cannot read: it only chooses
    the words of a report."""
    sign = host.effective("commit.gpgsign", "bool")
    if not (sign.set and sign.text == "true"):
        return False
    if host.effective("gpg.format").text != "ssh":
        return False
    return host.effective("user.signingkey").unset and host.effective("gpg.ssh.defaultKeyCommand").unset


# What the automatic step adds to its one line when commits_fail_closed(),
# quoted in docs/troubleshooting.md with its leading "; ". The SSH-session
# line in auto() spells the same words out in a second literal: the docs
# quote that line whole, and tests/troubleshooting_messages_test.sh looks
# for each quoted fragment verbatim in the source, which a line joined at
# run time would not match. Change both literals together.
FAIL_CLOSED = "; every commit fails until this host has a signing key - run %s identity on this host, or opt it out of signing (see docs/signing-key.md)"


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
        for said in entries:
            warn(said)
        hint_rerun(host)
        return 1
    keys, why = host.agent()
    if keys is None:
        warn(why)
        warn("identity:   load this host's signing key with ssh-add, then run:")
        warn("identity:   %s identity [--name \"Full Name\"]" % shell_word(host.installer))
        return 1
    if refuse_unclear(host, keys, path):
        return 1
    pairs = host.candidates(entries, keys)
    if not pairs:
        said = host.why_no_candidate(entries, keys, path)
        if said:
            warn(said)
            warn("identity:   load a key that is not revoked, list it in the allowed-signers file,")
            hint_rerun(host)
            return 1
        warn("identity: no ssh-agent key is listed for the git namespace in %s - writing nothing" % _shown(path))
        warn("identity:   add `<email> <keytype> <key>` for this host's signing key there,")
        hint_rerun(host)
        return 1
    email_v = host.effective("user.email")
    if email_v.error:
        warn("identity: cannot read user.email (%s) - writing nothing" % _shown(email_v.err))
        return 1
    if email_v.set and not any(p == email_v.text for p, _ in pairs):
        # Name the cause when the revocation file is what removed this
        # email's keys, rather than calling them unlisted.
        mine = [e for e in entries if match_pattern_list(email_v.text, e.principals)]
        said = host.why_no_candidate(mine, keys, path, email_v.text)
        if said:
            warn(said)
            warn("identity:   load a key for %s that is not revoked, then re-run" % _shown(email_v.text))
            return 1
    chosen, lines = select(host, pairs, email_v.text if email_v.set else "")
    if chosen is None:
        for said in lines:
            warn(said)
        return 1
    email, sigkey = chosen

    desired = []
    if name is not None:
        desired.append(("user.name", name, None))
    desired += [
        ("user.email", email, None),
        ("user.signingkey", "key::%s %s" % sigkey, None),
        # Effectively true already wherever git reads the tracked config, so
        # this is written only where it does not (and an existing copy in
        # config.local is left alone, like any equal value).
        ("commit.gpgsign", "true", "bool"),
    ]
    # A host that opted out of commit signing never has tag signing turned on
    # for it: tag.gpgsign = true there would sign tags only, which is not
    # what an operator who said false asked for. A tag.gpgsign it already set
    # is still compared below, like any other value.
    tag_kept = None
    if opted_out(host) and host.effective("tag.gpgsign", "bool").unset:
        tag_kept = "identity: tag.gpgsign is left unset while commit.gpgsign is false (this host opted out of signing)"
    else:
        desired.append(("tag.gpgsign", "true", "bool"))
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
                 % (_shown(path), _shown(cur.text)))
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
            warn("identity: cannot read %s (%s) - leaving it" % (key, _shown(bad[0].err)))
            conflicts += 1
            continue
        if typ == "bool" and eff.set and eff.text == "false" and not (local.set and local.text == "true"):
            # An effective false that config.local does not contradict is this
            # host's exception to signing (an operator decision): kept, and not
            # a conflict, so the email and the key are still written. A true
            # in config.local that another level overrides is NOT one: it is
            # reported as overridden below.
            kept.append("identity: %s is false (%s) - kept as this host's exception, so it stays off"
                        % (key, _shown(last_origin(host, key))))
            continue
        if typ == "bool" and local.set and local.text == "false" and eff.set and eff.text == "true":
            # The reverse: config.local says false, a later level says true and
            # wins. Nothing to write; the effective value is what signs.
            kept.append("identity: %s is false in %s, but %s sets it true and wins"
                        % (key, _shown(host.config_local), _shown(last_origin(host, key))))
            continue
        if local.set and equal_value(host, key, local.text, want, sigkey):
            # Right in config.local, but another level may still win: the
            # value a commit sees is the effective one.
            if eff.set and not equal_value(host, key, eff.text, want, sigkey):
                warn("identity: %s is overridden by %s - leaving it: %s" % (key, _shown(last_origin(host, key)), _shown(eff.text)))
                conflicts += 1
            continue
        cur = local if local.set else eff
        if not cur.set:
            to_write.append((key, want, typ))
        elif not equal_value(host, key, cur.text, want, sigkey):
            warn("identity: %s is already set to a different value - leaving it: %s" % (key, _shown(cur.text)))
            conflicts += 1

    if tag_kept:
        kept.append(tag_kept)
    if _captured is None:
        for said in kept:
            log(said)
    if conflicts:
        # Nothing at all next to a conflict: an email, or tag.gpgsign = true,
        # written beside a signing key this step did not choose would pair
        # this host's identity with a key that may not verify for it.
        # Where git reads the tracked config, commit signing comes from it
        # either way; elsewhere commit.gpgsign = true is withheld too.
        warn("identity:   writing nothing; fix the value(s) above, or keep them on purpose")
        return 1
    if to_write:
        # Prove git reads config.local BEFORE writing to it: a file nothing
        # includes is written but never read.
        included, err = host.includes_local()
        if err is not None:
            warn("identity: cannot read include.path (%s) - writing nothing" % _shown(err))
            return 1
        if not included:
            warn("identity: git does not read %s (no [include] reaches it) - writing nothing" % _shown(host.config_local))
            warn("identity:   see \"Framework git settings do not apply\" in docs/troubleshooting.md")
            return 1
        if not write_keys(host.config_local, [(k, v) for k, v, _ in to_write]):
            return 1
        log("identity: wrote %s to %s" % (", ".join(k for k, _, _ in to_write), _shown(host.config_local)))
        if _captured is not None:
            for said in kept:
                log(said)
        # Read every written key back through the effective config: a later
        # file can still override what was just written.
        for key, want, typ in to_write:
            back = host.effective(key, typ)
            if not back.set or not equal_value(host, key, back.text, want, sigkey):
                origins = host.origins(key)
                origin = origins[-1][0] if origins else "nowhere"
                warn("identity: %s reads %s from %s after the write, not the value written"
                     % (key, quoted(back.text) if back.set else "unset", _shown(origin)))
                conflicts += 1
    elif not conflicts:
        log("identity: already configured for %s (%s)" % (_shown(email), fingerprint(sigkey)))

    if conflicts:
        return 1
    if host.effective("user.name").unset:
        warn(missing_name_line(host))
    return 0


def rotate(host):
    """Replace ONLY user.signingkey, and only when the configured key no longer
    verifies for user.email and exactly one agent key does."""
    if not require_ssh_format(host) or not require_revocation(host):
        return 1
    email_v = host.effective("user.email")
    if email_v.error:
        warn("identity: cannot read user.email (%s) - writing nothing" % _shown(email_v.err))
        return 1
    if not email_v.set:
        warn("identity: --rotate needs user.email - run %s identity first" % shell_word(host.installer))
        return 1
    email = email_v.text
    origins, err = host.origins_or_error("user.signingkey")
    if err is not None:
        warn("identity: --rotate: cannot read user.signingkey (%s) - writing nothing" % _shown(err))
        return 1
    if not origins:
        warn("identity: --rotate: user.signingkey is not set - nothing to rotate; run %s identity" % shell_word(host.installer))
        return 1
    origin, old_value = origins[-1]
    if not host.is_local_origin(origin):
        warn("identity: --rotate: user.signingkey comes from %s, not %s - edit it there"
             % (_shown(origin), _shown(host.config_local)))
        return 1
    old, _ = resolve_signingkey(old_value, host.home)
    if old is None:
        warn("identity: --rotate: user.signingkey (%s) names no readable public key - refusing" % _shown(old_value))
        return 1
    path, _, entries = host.signers()
    if path is None:
        for said in entries:
            warn(said)
        return 1
    why = host.why_invalid(entries, old, email)
    if why is None:
        warn("identity: --rotate: %s is still valid for %s in %s - nothing to rotate"
             % (fingerprint(old), _shown(email), _shown(path)))
        return 1
    keys, said = host.agent()
    if keys is None:
        warn(said)
        return 1
    if refuse_unclear(host, keys, path):
        return 1
    new = sorted(set(k for p, k in host.candidates(entries, keys) if p == email))
    if len(new) != 1:
        warn("identity: --rotate: %d ssh-agent keys are valid for %s in %s - refusing"
             % (len(new), _shown(email), _shown(path)))
        for k in new:
            warn("identity:   key %s" % fingerprint(k))
        return 1
    new = new[0]
    value = "key::%s %s" % new
    if not write_keys(host.config_local, [("user.signingkey", value)]):
        return 1
    log("identity: rotated user.signingkey for %s: %s -> %s (old key: %s)"
        % (_shown(email), fingerprint(old), fingerprint(new), why))
    log("identity:   it was: %s" % _shown(old_value))
    back = host.effective("user.signingkey")
    if not back.set or resolve_signingkey(back.text, host.home)[0] != new:
        warn("identity: user.signingkey reads %s after the write, not the new key" % quoted(back.text))
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


def check_signing_key(host, agent_said=False):
    """Report an effective user.signingkey that will not work, or that comes
    from outside config.local. Returns True when something was reported.
    AGENT_SAID: the caller already reports an agent it cannot read (doctor's
    ssh-agent check), so a key "not loaded" there would be a second line for
    the same cause."""
    fmt = host.effective("gpg.format")
    if fmt.error:
        warn("identity: cannot read gpg.format (%s) - user.signingkey not checked" % _shown(fmt.err))
        return True
    if fmt.text != "ssh":
        return False  # a GPG key id is not ours to judge
    origins, err = host.origins_or_error("user.signingkey")
    if err is not None:
        warn("identity: cannot read user.signingkey (%s) - not checked" % _shown(err))
        return True
    if not origins:
        return False
    reported = False
    outside = [o for o, _ in origins if not host.is_local_origin(o)]
    for origin in outside:
        tail = " - the last one git reads wins" if len(origins) > 1 else ""
        warn("identity: user.signingkey is set in %s, outside %s%s" % (_shown(origin), _shown(host.config_local), tail))
        reported = True
    value = origins[-1][1]
    key, needs_agent = resolve_signingkey(value, host.home)
    if key is None and signingkey_uncheckable(value, host.home):
        warn("identity: user.signingkey (%s) is a certificate or a private key without its .pub - not checked"
             % _shown(value))
        return reported
    if key is None:
        warn("identity: user.signingkey (%s) names no readable SSH public key - signing will fail" % _shown(value))
        return True
    _, said = host.revocation()
    stale = None if said else stale_reason(host, key)
    if said:
        warn(_untailed(said))
        reported = True
    elif stale is not None:
        email, path, why = stale
        warn("identity: user.signingkey %s is not valid for %s in %s (%s)"
             % (fingerprint(key), _shown(email), _shown(path), why))
        warn("identity:   new signatures will not verify; run: %s identity --rotate" % shell_word(host.installer))
        reported = True
    if needs_agent:
        keys, _ = host.agent()
        if (keys is None and not agent_said) or (keys is not None and key not in keys):
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
    what = "; ".join("%s = false from %s" % (k, _shown(o)) for k, o in found)
    warn("identity: signing is off against %s: %s - see %s identity"
         % (_shown(host.config_local), what, shell_word(host.installer)))
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
    # origins(): a read error is nothing to judge, and this report stays
    # quiet on what it cannot judge (identity and check name the error).
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
    warn(msg % (fingerprint(key), _shown(email), _shown(path), why, shell_word(host.installer)))
    return 1


def auto(host):
    """The automatic step on a host that does not sign yet: one line when it
    cannot act. Returns (exit status, suffix): when it leaves the host with
    commit signing on and no key, the suffix is FAIL_CLOSED, which main()
    appends to that one line; otherwise None. Returned, not kept in module
    state, so nothing carries over to a later main() in the same process."""
    # Over SSH the agent is usually forwarded from ANOTHER machine, whose
    # keys are not this host's to sign with. One literal each:
    # docs/troubleshooting.md quotes them verbatim.
    if os.environ.get("SSH_CONNECTION"):
        if commits_fail_closed(host):
            msg = "identity: not set automatically in an SSH session (a forwarded agent holds another machine's keys); every commit fails until this host has a signing key - run %s identity on this host, or opt it out of signing (see docs/signing-key.md)"
        else:
            msg = "identity: not set automatically in an SSH session (a forwarded agent holds another machine's keys) - run %s identity to set it on purpose"
        warn(msg % shell_word(host.installer))
        return 1, None
    rc = identity(host, None)
    if rc != 0 and commits_fail_closed(host):
        return rc, FAIL_CLOSED % shell_word(host.installer)
    return rc, None


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
         % (_shown(glob), _shown(xdg_config), _shown(host.config_local)))
    return False


def local_absent_or_regular(host):
    """False when config.local exists and is not a regular file. Checked
    before any git read: git opens it through the include, and a FIFO there
    would hold every read to its 30 s timeout."""
    try:
        st = os.stat(host.config_local)
    except OSError:
        return True  # absent, or unreachable: write_keys() reports that
    return stat.S_ISREG(st.st_mode)


def local_is_regular(host):
    """local_absent_or_regular(), saying why when it is False."""
    if local_absent_or_regular(host):
        return True
    warn("identity: %s is not a regular file - writing nothing" % _shown(host.config_local))
    return False


# --- ~/.gitconfig and the install-time advisory -------------------------------

# The keys that make a ~/.gitconfig shadow the identity or signing settings.
# ONE list: the advisory and doctor both read ~/.gitconfig through
# gitconfig_finding().
GITCONFIG_IDENTITY = r"^(user\.|gpg\.|commit\.gpgsign|tag\.gpgsign)"


def gitconfig_finding(host):
    """(level, text) about ~/.gitconfig, level ok, info or problem.

    git reads ~/.gitconfig AFTER the XDG config, so whatever it sets wins,
    and `git config --global` then reads and writes only that file. A
    DANGLING one is inert today but comes back to life, old settings and all,
    the day its target is restored from a backup. One that carries signing
    settings can pit a legacy GPG signingkey against the framework's
    gpg.format = ssh and make every commit fail closed. Each text is ONE
    literal: docs/troubleshooting.md quotes them."""
    path = os.path.join(host.home, ".gitconfig")
    if not os.path.lexists(path):
        return "ok", "no ~/.gitconfig"
    if not os.path.exists(path):
        return "problem", "a dangling ~/.gitconfig symlink is in place, and its target's settings would override ~/.config/git/config - remove it"
    if not os.path.isfile(path):
        return "problem", "~/.gitconfig is not a regular file - remove it"
    rc, out, _ = git(["config", "--file", path, "--name-only", "--get-regexp", GITCONFIG_IDENTITY])
    names = sorted(set(out.split("\n"))) if rc == 0 and out else []
    if names:
        return "problem", ("~/.gitconfig sets %s, and git reads it after ~/.config/git/config - move its settings into %s and remove it"
                           % (", ".join(escape(n) for n in names), _shown(host.config_local)))
    return "info", "~/.gitconfig exists (no identity or signing settings); git config --global reads and writes only it"


def advisory(host):
    """`check`: the install-time advisory (_signing_advisory), decided here
    in one place. The tracked git config sets commit.gpgsign = true, so an
    unset one means git does not read that config at all, and a host with
    no signing key cannot commit (commits_fail_closed()). Prints nothing
    about signing on a host that opted out (opted_out()); ~/.gitconfig is
    reported either way, since it shadows the identity of every commit,
    signed or not. Always returns 0."""
    level, finding = gitconfig_finding(host)
    if level != "ok":
        warn(finding)
    if opted_out(host):
        return 0
    inst = shell_word(host.installer)
    sign = host.effective("commit.gpgsign", "bool")
    if sign.error:
        warn("commit.gpgsign is not a boolean git reads (%s) - git refuses every commit until it is fixed"
             % _shown(sign.err))
        return 0
    if sign.unset:
        # The tracked config sets it, so git does not read the tracked config.
        warn("commit signing is NOT enabled on this host (commit.gpgsign is unset).")
        warn("  The framework git config sets it, so git does not read that config here:")
        warn('  see "Framework git settings do not apply" in docs/troubleshooting.md.')
        return 0
    if commits_fail_closed(host):
        warn("commit signing is on, but user.signingkey is not set, so git refuses every commit.")
        warn("  Run %s identity on this host, or opt it out of signing" % inst)
        warn("  (see docs/signing-key.md).")
    overridden = overridden_signing(host)
    if sign.text == "false":
        warn("commit signing is NOT enabled on this host (commit.gpgsign is false).")
        origin = last_origin(host, "commit.gpgsign")
        if host.is_local_origin(origin):
            # config.local says false, but tag.gpgsign = true keeps it from
            # being an opt-out (opted_out()).
            warn("  tag.gpgsign is true, so tags are still signed and the key below is checked.")
        elif not any(k == "commit.gpgsign" for k, _ in overridden):
            warn("  An explicit false from %s is kept as this host's exception, and" % _shown(origin))
            warn("  %s identity leaves it. To sign, remove it there; to keep" % inst)
            warn("  this host from signing on purpose, set the false in %s." % _shown(host.config_local))
    # A stale key, a user.signingkey set outside config.local, and a gpgsign
    # that a later file turns off against config.local. identity() reports
    # the last itself, as a conflict; only check says it here.
    check_signing_key(host)
    for key, origin in overridden:
        warn("identity: %s is true in %s, but %s sets it false and wins - signing stays off"
             % (key, _shown(host.config_local), _shown(origin)))
    return 0


# --- doctor: read-only checks -------------------------------------------------
#
# `install.sh doctor` runs every check in CHECKS, in order. A check is one
# method of Doctor: it only reads (git config, files, `ssh-add -L`,
# `ssh-keygen`) and records findings. It opens no network connection of its
# own, though a forwarded agent answers over its SSH session. Each tool runs
# under a timeout; each file is opened without blocking and read up to a
# size cap (read_small_file()). A finding is ok, info or a problem; a
# problem is one line naming what is wrong, where it comes from and the fix,
# written as ONE literal so docs/troubleshooting.md can quote it
# (tests/troubleshooting_messages_test.sh). By default only the problems
# print; --verbose prints every finding and a verdict. On a host that opted
# out of signing (opted_out()), a problem marked signing-only is recorded as
# info instead: that host chose not to sign. A new dependency joins as one
# more method and one more CHECKS entry.

# git signs with SSH keys from 2.34 on (gpg.format = ssh).
GIT_SSH_SIGNING = (2, 34)
TOOL_TIMEOUT = 15


WRITING_NOTHING = " - writing nothing"


def _untailed(msg):
    """MSG without its ` - writing nothing` tail. Only a tail: the same
    words inside a path the message names stay as they are."""
    return msg[:-len(WRITING_NOTHING)] if msg.endswith(WRITING_NOTHING) else msg


def _bare(msg):
    """A refusal message without its `identity: ` head and its
    ` - writing nothing` tail: the cause alone."""
    if msg.startswith("identity: "):
        msg = msg[len("identity: "):]
    return _untailed(msg)


def _capture(fn, *args):
    """Run FN with warn() collecting instead of printing: (result, lines)."""
    global _captured
    saved, _captured = _captured, []
    try:
        result = fn(*args)
    finally:
        lines, _captured = _captured, saved
    return result, lines


def _grouped(lines):
    """Warning lines folded into one line per cause: each indented hint joins
    the line before it."""
    out = []
    for said in lines:
        if said.startswith("identity:   ") and out:
            out[-1] += " - " + said[len("identity:   "):]
        else:
            out.append(_bare(said))
    return out


class Doctor(object):
    """The checks of `install.sh doctor`. A check method records what it
    found in self.found; doctor() runs CHECKS and labels each finding with
    the name of the check that recorded it."""

    def __init__(self, host):
        self.host = host
        self.found = []  # (level, text)
        self.opted_out_origin = opted_out(host)

    def ok(self, text):
        self.found.append(("ok", text))

    def info(self, text):
        self.found.append(("info", text))

    def problem(self, line, signing=False):
        """LINE is a problem. SIGNING marks one that matters only to signing:
        on a host that opted out of signing it is a note instead. The name,
        the email, the include chain and ~/.gitconfig shape every commit,
        signed or not, so they never pass SIGNING."""
        level = "info" if signing and self.opted_out_origin else "problem"
        self.found.append((level, line))

    # One method per dependency or value group; CHECKS orders them.

    def git(self):
        host = self.host
        rc, out, err = git(["--version"])
        if rc != 0:
            self.problem("git did not run (%s) - install the Command Line Tools (xcode-select --install)"
                         % (_shown(err or out) if err or out else "exit %d" % rc))
            return
        m = re.match(r"git version (\d+)\.(\d+)", out)
        if m and (int(m.group(1)), int(m.group(2))) < GIT_SSH_SIGNING:
            self.problem("%s cannot sign with SSH keys (2.34 or later can) - upgrade git" % _shown(out), signing=True)
        else:
            self.ok(_shown(out))
        glob = os.environ.get("GIT_CONFIG_GLOBAL")
        xdg_config = os.path.join(os.path.dirname(host.config_local), "config")
        if glob is not None and not same_file(glob, xdg_config):
            self.problem("GIT_CONFIG_GLOBAL=%s is not %s, so git does not read %s - unset it"
                         % (_shown(glob), _shown(xdg_config), _shown(host.config_local)))
            return
        included, err = host.includes_local()
        if included:
            self.ok("an [include] reaches %s" % _shown(host.config_local))
        elif err is not None:
            self.problem("cannot read include.path (%s) - check the file git -C ~ config --show-origin --get-all include.path names"
                         % _shown(err))
        else:
            self.problem('no [include] reaches %s, so git never reads it - see "Framework git settings do not apply" in docs/troubleshooting.md'
                         % _shown(host.config_local))

    def python3(self):
        # Reached only through a python3 that runs: install.sh reports one
        # that does not before calling this file.
        self.ok("%s (%s)" % (platform.python_version(), _shown(sys.executable)))

    def ssh_keygen(self):
        path = shutil.which("ssh-keygen")
        if path is None:
            self.problem("ssh-keygen was not found on PATH - git signs and verifies with it; install OpenSSH",
                         signing=True)
            return
        # -Y against empty inputs: a build that knows -Y fails on the input,
        # one that does not rejects the option itself.
        try:
            p = subprocess.run(
                [path, "-Y", "find-principals", "-s", os.devnull, "-f", os.devnull],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=TOOL_TIMEOUT,
            )
        except (OSError, subprocess.TimeoutExpired) as e:
            self.problem("ssh-keygen did not run (%s) - git signs and verifies with it; install OpenSSH" % _shown(e),
                         signing=True)
            return
        said = (p.stdout + p.stderr).decode("utf-8", "replace")
        if "option -- Y" in said or "usage:" in said:
            self.problem("%s does not support -Y, which git signs and verifies with - install OpenSSH 8.2 or later"
                         % _shown(path), signing=True)
        else:
            self.ok("%s supports -Y" % _shown(path))

    def values(self):
        host = self.host
        inst = shell_word(host.installer)
        cl = host.config_local
        off = self.opted_out_origin
        for key in ("user.name", "user.email", "user.useConfigOnly", "user.signingkey", "commit.gpgsign",
                    "tag.gpgsign", "gpg.format", "gpg.ssh.allowedSignersFile", "gpg.ssh.revocationFile"):
            origins = host.origins(key)
            if origins:
                origin, value = origins[-1]
                self.ok("%s = %s (%s)" % (key, _shown(value), _shown(origin)))
            else:
                self.ok("%s is unset" % key)
        fmt = host.effective("gpg.format")
        if not (fmt.set and fmt.text == "ssh"):
            self.problem('gpg.format is %s, not ssh - see "Framework git settings do not apply" in docs/troubleshooting.md'
                         % (quoted(fmt.text) if fmt.set else "unset"), signing=True)
        # The tracked config sets user.useConfigOnly = true: git then refuses
        # every commit, signed or not, without a user.name and a user.email,
        # so the lines for those two say so. A false (config.local may set
        # one) lets git invent both from the account and host name instead.
        only = host.effective("user.useConfigOnly", "bool")
        refuses = only.set and only.text == "true"
        if only.set and only.text == "false":
            self.info("user.useConfigOnly = false from %s: git invents a name and an email from this account and host when none is set"
                      % _shown(last_origin(host, "user.useConfigOnly")))
        # Each line ONE literal, fix included: docs/troubleshooting.md quotes
        # them. The `git config --file` fixes are an opted-out host's, where
        # `install.sh identity` needs a signing key.
        if refuses:
            name_local = 'user.name is not set, so git refuses every commit - run: git config --file %s user.name "Full Name"'
            name_step = 'user.name is not set, so git refuses every commit - run: %s identity --name "Full Name"'
            email_local = "user.email is not set, so git refuses every commit - run: git config --file %s user.email <your email>"
            email_step = "user.email is not set, so git refuses every commit - run: %s identity"
        else:
            name_local = 'user.name is not set - run: git config --file %s user.name "Full Name"'
            name_step = 'user.name is not set - run: %s identity --name "Full Name"'
            email_local = "user.email is not set - run: git config --file %s user.email <your email>"
            email_step = "user.email is not set - run: %s identity"
        for key in ("user.name", "user.email", "user.signingkey"):
            signing = key == "user.signingkey"
            v = host.effective(key)
            if v.error:
                self.problem("cannot read %s (%s) - check the file git -C ~ config --show-origin --get %s names"
                             % (key, _shown(v.err), key), signing=signing)
            elif v.unset and key == "user.name":
                self.problem(name_local % shell_word(cl) if off else name_step % inst)
            elif v.unset and key == "user.email":
                self.problem(email_local % shell_word(cl) if off else email_step % inst)
            elif v.unset and signing and commits_fail_closed(host):
                self.problem("user.signingkey is not set, so git refuses every commit - run: %s identity, or opt this host out of signing (see docs/signing-key.md)"
                             % inst, signing=True)
            elif v.unset:
                self.problem("%s is not set - run: %s identity" % (key, inst), signing=signing)
        for key, verb in (("user.useConfigOnly", "run most commands"), ("commit.gpgsign", "commit"),
                          ("tag.gpgsign", "tag")):
            v = host.effective(key, "bool")
            if v.error:
                # git dies on such a value: `fatal: bad boolean config value`.
                self.problem("%s is not a boolean git reads (%s) - git refuses to %s until it is; fix it in the file git -C ~ config --show-origin --get %s names"
                             % (key, _shown(v.err), verb, key))
        sign = host.effective("commit.gpgsign", "bool")
        overridden = overridden_signing(host)
        if off:
            # One literal: docs/signing-key.md quotes it verbatim.
            msg = "commit.gpgsign = false from %s: respected as this host's opt-out; the automatic step stays quiet and writes nothing"
            self.ok(msg % _shown(off))
        elif sign.unset:
            # The tracked config sets it: unset means that config is not read.
            self.problem('commit.gpgsign is not set, so git does not read the framework git config and commits are not signed - see "Framework git settings do not apply" in docs/troubleshooting.md')
        elif sign.set and sign.text == "false" and not any(k == "commit.gpgsign" for k, _ in overridden):
            origin = last_origin(host, "commit.gpgsign")
            if host.is_local_origin(origin):
                self.info("commit.gpgsign = false from %s, but tag.gpgsign is true: tags are signed, so the signing checks apply"
                          % _shown(origin))
            else:
                # Not an opt-out (opted_out()): a file outside config.local
                # may be nobody's decision for this host.
                self.problem("commit.gpgsign = false from %s, outside %s, so commits are not signed - remove it there to sign, or set the false in %s to opt out"
                             % (_shown(origin), _shown(cl), _shown(cl)))
        for key, origin in overridden:
            self.problem("%s is true in %s, but %s sets it false and wins - remove the false there, or the true in %s"
                         % (key, _shown(cl), _shown(origin), _shown(cl)))
        if host.effective("gpg.ssh.allowedSignersFile", "path").unset:
            self.problem("gpg.ssh.allowedSignersFile is not set, so git cannot verify signatures - run: %s identity"
                         % inst, signing=True)

    def trust_root(self):
        host = self.host
        path, source, entries = host.signers()
        if path is None:
            why = entries[0]  # the first line of the refusal (signers())
            self.problem("%s - see docs/signing-key.md" % _bare(why), signing=True)
            return
        n = len(entries)
        self.ok("%s (from %s): %d entr%s" % (_shown(path), source, n, "y" if n == 1 else "ies"))
        bad = host.malformed_lines()
        if bad:
            self.info("skipped malformed line(s) %s in %s" % (", ".join(str(k) for k in bad), _shown(path)))
        rev_path, why = host.revocation()
        if why:
            self.problem("%s - see docs/signing-key.md" % _bare(why), signing=True)
        elif rev_path:
            self.ok("gpg.ssh.revocationFile %s is readable" % _shown(rev_path))

    def ssh_agent(self):
        host = self.host
        keys, why = host.agent()
        sk = host.effective("user.signingkey")
        # A signingkey that is a private key file signs without the agent.
        needed = not sk.set or resolve_signingkey(sk.text, host.home)[1] is not False
        if keys is None:
            if needed:
                self.problem("%s - load this host's signing key with ssh-add" % _bare(why), signing=True)
            else:
                self.info(_bare(why))
            return
        self.ok("%d key(s) in the ssh-agent" % len(keys))
        path, _, entries = host.signers()
        if path is None:
            return
        unclear = host.unclear_lines(keys)
        if unclear:
            self.problem("malformed allowed-signers line(s) %s in %s name an ssh-agent key - fix or remove them"
                         % (", ".join(str(k) for k in unclear), _shown(path)), signing=True)
        pairs = sorted(host.candidates(entries, keys))
        for p, k in pairs:
            self.ok("%s is listed for %s in %s" % (fingerprint(k), _shown(p), _shown(path)))
        if not pairs:
            self.info("no ssh-agent key is listed for the git namespace in %s" % _shown(path))

    def signing_key(self):
        host = self.host
        # The stale-key report of `check` mode, read back as findings: one
        # line per cause, its hint joined to it. An agent that cannot be
        # read is the ssh-agent check's line, not a second one here.
        reported, lines = _capture(check_signing_key, host, True)
        for finding in _grouped(lines):
            if reported:
                self.problem(finding, signing=True)
            else:
                self.info(finding)
        origins = host.origins("user.signingkey")
        if reported or not origins or host.effective("gpg.format").text != "ssh":
            return
        key, needs_agent = resolve_signingkey(origins[-1][1], host.home)
        if key is None:
            return
        if needs_agent and host.agent()[0] is None:
            return
        email_v = host.effective("user.email")
        path, _, _ = host.signers()
        how = "loaded in the ssh-agent" if needs_agent else "signs from its private key file"
        if email_v.set and path is not None:
            self.ok("%s verifies for %s in %s, %s" % (fingerprint(key), _shown(email_v.text), _shown(path), how))
        else:
            self.ok("%s, %s (no user.email or allowed-signers file to verify it against)"
                    % (fingerprint(key), how))

    def ssh_session(self):
        if os.environ.get("SSH_CONNECTION"):
            self.info("SSH_CONNECTION is set: the automatic step writes nothing in this session; %s identity, run on purpose, still works"
                      % shell_word(self.host.installer))
        else:
            self.ok("not an SSH session")

    def gitconfig(self):
        level, finding = gitconfig_finding(self.host)
        if level == "problem":
            self.problem(finding)
        elif level == "info":
            self.info(finding)
        else:
            self.ok(finding)


# (name, Doctor method): the checks, in the order they print.
CHECKS = (
    ("git", Doctor.git),
    ("python3", Doctor.python3),
    ("ssh-keygen", Doctor.ssh_keygen),
    ("values", Doctor.values),
    ("trust root", Doctor.trust_root),
    ("ssh-agent", Doctor.ssh_agent),
    ("signing key", Doctor.signing_key),
    ("ssh session", Doctor.ssh_session),
    ("~/.gitconfig", Doctor.gitconfig),
)


def doctor(host, verbose):
    """Run CHECKS; print the problems (everything with VERBOSE). Writes
    nothing. Returns 1 when a problem was found, else 0."""
    if not local_absent_or_regular(host):
        # Before any git read (see local_absent_or_regular()); one literal,
        # quoted in docs/troubleshooting.md.
        log("doctor: git: %s is not a regular file - git opens it through the include; remove it or make it a file"
            % _shown(host.config_local))
        return 1
    reason = git_isolate()
    if reason is not None:
        # Every check reads through git(), so each would report this one
        # cause as a problem of its own (an unset gpg.format, a git that
        # did not run). One literal, quoted in docs/troubleshooting.md.
        log("doctor: git: not reading the git config: %s" % reason)
        return 1
    d = Doctor(host)
    findings = []
    for name, method in CHECKS:
        d.found = []
        method(d)
        findings += [(level, name, text) for level, text in d.found]
    problems = 0
    for level, check, finding in findings:
        if level == "problem":
            problems += 1
        if level == "problem" or verbose:
            # FINDING is printed as it is: each check put every value in it
            # through _shown(), so the literal around it stays bare.
            log("doctor: %s: %s%s" % (check, "note: " if level == "info" else "", finding))
    if verbose:
        if problems:
            log("doctor: verdict: %d problem(s) need action" % problems)
        elif d.opted_out_origin:
            log("doctor: verdict: signing is off on purpose on this host; nothing needs action")
        else:
            log("doctor: verdict: nothing needs action")
    return 1 if problems else 0


def run(host, mode, name, report_stale, verbose=False):
    """Dispatch one mode; returns (exit status, suffix for the automatic
    step's one line, or None). Only auto() returns a suffix."""
    if mode == "doctor":
        return doctor(host, verbose), None
    if not local_is_regular(host):
        return (0 if mode == "check" else 1), None
    # Before any git read, so a mode never acts on reads that only failed.
    reason = git_isolate()
    if reason is not None:
        warn("identity: not reading the git config: %s" % reason)
        return (0 if mode == "check" else 1), None
    if mode == "check":
        return advisory(host), None
    # An opted-out host (commit.gpgsign = false in config.local, its own
    # decision; see opted_out()) hears nothing from the automatic step, and
    # nothing is written for it: not on install, not on link, so not on any
    # upgrade. `install.sh doctor` says why; `install.sh identity`, run on
    # purpose, still works.
    if mode == "auto" and opted_out(host):
        return 0, None
    if mode == "auto" and already_configured(host):
        if not report_stale:
            return 0, None
        # One line at most: main() keeps only the first warning.
        return (overridden_line(host) or stale_line(host)), None
    if mode == "auto" and signing_configured(host) and host.effective("user.name").unset:
        # Only user.name is missing, which the step never writes. Its line is
        # the one line, ahead of a stale-key or override line: under the
        # tracked user.useConfigOnly = true git refuses every commit without
        # a name, while a stale key only leaves new signatures unverified.
        # Not through identity(): with the email and key in place it would
        # write nothing, and an unreachable agent would bury the name line
        # under an agent line. The next run, once the name is set, reports
        # the stale key. A user.name git cannot read is not "not set": it
        # falls through to identity(), like any other failed read (git fails
        # a read for the whole config, so the email's read names the error).
        warn(missing_name_line(host))
        return 0, None
    if not global_reads_local(host):
        return 1, None
    if mode == "rotate":
        return rotate(host), None
    if mode == "auto":
        return auto(host)
    rc = identity(host, name)
    return (1 if check_signing_key(host) else rc), None


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
    ap.add_argument("--mode", choices=("auto", "identity", "rotate", "check", "doctor"), required=True)
    ap.add_argument("--name")
    ap.add_argument("--report-stale", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)
    if args.report_stale and args.mode != "auto":
        warn("identity: --report-stale is taken only by --mode auto")
        return 2
    if args.verbose and args.mode != "doctor":
        warn("identity: --verbose is taken only by --mode doctor")
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
    # auto reduces its warnings to one line below; doctor reports through its
    # own findings, so a warning a shared helper prints is dropped there.
    if args.mode in ("auto", "doctor"):
        _captured = []
    try:
        rc, consequence = run(host, args.mode, args.name, args.report_stale, args.verbose)
    finally:
        git_release()
        lines, _captured = _captured, None
    if args.mode == "doctor":
        lines = []
    # Precedence among auto's one-line warnings: a missing user.name or
    # user.email comes first, since git refuses every commit without it
    # (the tracked user.useConfigOnly). A missing email is never a line of
    # its own: the step writes it, or the headline names why it cannot. A
    # missing name on an otherwise configured host is printed alone by
    # run(), ahead of a stale-key or override line. A host missing both
    # hears the cause first: a run that writes the email prints its `wrote`
    # line (log(), not a warning) and then the name line, since rc 0 keeps
    # every warning; a run that cannot write prints its one cause line, and
    # the name line comes on a later run.
    # Each line is printed as it is: every value in it went through
    # _shown() or shell_word() where it was put in, the suffixes' installer
    # path included, so this is no place to escape it a second time.
    if lines:
        if rc == 0:
            for said in lines:
                warn(said)
        else:
            said = headline(lines)
            if consequence:
                said += consequence
            elif "%s identity" % shell_word(host.installer) not in said:
                said += " (details: %s identity)" % shell_word(host.installer)
            warn(said)
    return rc


class Terminated(BaseException):
    """A SIGTERM or SIGHUP, raised where the process is, as ^C raises
    KeyboardInterrupt, so every finally on the way out runs (the KRL key
    file, git's empty directory). A BaseException, so no `except
    Exception` swallows it."""

    def __init__(self, signum):
        BaseException.__init__(self, signum)
        self.signum = signum


def _terminated(signum, frame):
    raise Terminated(signum)


def _die_of(signum):
    """End this process by SIGNUM itself, not a plain exit: a shell waiting
    on it then sees the signal, as it would for any command killed by it."""
    signal.signal(signum, signal.SIG_DFL)
    os.kill(os.getpid(), signum)
    return 128 + signum  # only if SIGNUM is blocked


def entry(argv):
    """main(), with an interrupt or a termination reported without a
    traceback. main()'s finally has already removed git's empty directory
    by then, and krl_revokes() its key file. A SIGTERM or SIGHUP the caller
    left at its default unwinds like ^C (Terminated); one it ignores (nohup)
    stays ignored."""
    for signum in (signal.SIGTERM, signal.SIGHUP):
        if signal.getsignal(signum) == signal.SIG_DFL:
            signal.signal(signum, _terminated)
    try:
        return main(argv)
    except KeyboardInterrupt:
        return _die_of(signal.SIGINT)
    except Terminated as e:
        return _die_of(e.signum)


if __name__ == "__main__":
    sys.exit(entry(sys.argv[1:]))
