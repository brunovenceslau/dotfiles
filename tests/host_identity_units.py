# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Unit checks for lib/host_identity.py that the end-to-end cases in
# tests/host_identity_test.sh cannot stage through install.sh, called as
#   python3 -I -B tests/host_identity_units.py MODULE SCRATCH
# SCRATCH is an empty directory this run may write in. Each check prints one
# line; any failure exits 1. A separate .py file for the reason
# tests/host_identity_conformance.py gives.

import ast
import base64
import errno
import importlib.util
import os
import stat
import struct
import subprocess
import sys

failures = []


def check(cond, what):
    print(("ok: " if cond else "FAIL: ") + what)
    if not cond:
        failures.append(what)


def load(path):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("host_identity", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def wire(*parts):
    return b"".join(struct.pack(">I", len(p)) + p for p in parts)


def key_line(*parts):
    return "%s %s" % (parts[0].decode(), base64.b64encode(wire(*parts)).decode())


def stub(directory, name, body):
    path = os.path.join(directory, name)
    with open(path, "w") as fh:
        fh.write("#!/bin/sh\n" + body)
    os.chmod(path, stat.S_IRWXU)


def main(argv):
    module, scratch = argv
    with open(module, encoding="utf-8") as fh:
        source = fh.read()
    # The Python 3.9 floor (the macOS Command Line Tools python3): newer
    # grammar would only fail on the hosts this file exists for.
    try:
        ast.parse(source, filename=module, feature_version=(3, 9))
        check(True, "lib/host_identity.py parses as Python 3.9")
    except SyntaxError as e:
        check(False, "lib/host_identity.py parses as Python 3.9: %s" % e)
    mod = load(module)

    # --- the git environment: what is scrubbed, what survives ---------------
    saved = dict(os.environ)
    os.environ.update({
        "GIT_DIR": "/some/repo/.git",
        "GIT_WORK_TREE": "/some/repo",
        "GIT_CONFIG_PARAMETERS": "'user.email'='evil@x'",
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "user.email",
        "GIT_CONFIG_VALUE_0": "evil@x",
        "GIT_CONFIG_GLOBAL": "/custom/global",
        "GIT_CONFIG_SYSTEM": "/custom/system",
        "GIT_CONFIG_NOSYSTEM": "1",
    })
    env = mod.git_env()
    check(env.get("GIT_DIR") == mod.NO_REPO, "git_env pins GIT_DIR to the no-repository path")
    check(not any(k in env for k in ("GIT_WORK_TREE", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
                                     "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0")),
          "git_env drops the repository-local and -c variables")
    check(env.get("GIT_CONFIG_GLOBAL") == "/custom/global" and env.get("GIT_CONFIG_SYSTEM") == "/custom/system"
          and env.get("GIT_CONFIG_NOSYSTEM") == "1", "git_env keeps the global and system file selectors")
    bindir = os.path.join(scratch, "bin")
    os.mkdir(bindir)
    record = os.path.join(scratch, "git-env")
    stub(bindir, "git", 'env > "%s"\nexit 1\n' % record)
    os.environ["PATH"] = bindir + os.pathsep + os.environ["PATH"]
    mod.git(["config", "--get", "user.email"])
    with open(record) as fh:
        seen = dict(line.split("=", 1) for line in fh.read().splitlines() if "=" in line)
    check(seen.get("GIT_DIR") == mod.NO_REPO and "GIT_CONFIG_PARAMETERS" not in seen
          and seen.get("GIT_CONFIG_GLOBAL") == "/custom/global" and seen.get("GIT_CONFIG_NOSYSTEM") == "1",
          "the git child process sees exactly the scrubbed environment")
    os.environ.clear()
    os.environ.update(saved)

    # --- keys: types, exact blob structure, agent noise ---------------------
    for kind in ("rsa", "ecdsa"):
        path = os.path.join(scratch, kind)
        subprocess.run(["ssh-keygen", "-q", "-t", kind, "-N", "", "-f", path], check=True,
                       stdin=subprocess.DEVNULL)
        with open(path + ".pub") as fh:
            check(mod.parse_key(fh.read()) is not None, "an ssh-keygen %s public key parses" % kind)
    sk_ed = key_line(b"sk-ssh-ed25519@openssh.com", b"\x01" * 32, b"ssh:")
    sk_ec = key_line(b"sk-ecdsa-sha2-nistp256@openssh.com", b"nistp256", b"\x04" + b"\x02" * 64, b"ssh:")
    check(mod.parse_key(sk_ed) is not None, "an sk-ssh-ed25519 key parses")
    check(mod.parse_key(sk_ec) is not None, "an sk-ecdsa key parses")
    ed = key_line(b"ssh-ed25519", b"\x03" * 32)
    check(mod.parse_key(ed + " comment") is not None, "an ed25519 key with a comment parses")
    check(mod.parse_key(key_line(b"ssh-ed25519", b"\x03" * 32, b"extra")) is None,
          "a blob with trailing data is refused")
    check(mod.parse_key(key_line(b"ssh-rsa", b"\x03" * 32)) is None, "a blob whose type disagrees is refused")
    check(mod.parse_key(key_line(b"ssh-ed25519", b"\x03" * 31)) is None, "a short ed25519 key is refused")
    for cert in ("ssh-ed25519-cert-v01@openssh.com", "ssh-rsa-cert-v01@openssh.com",
                 "ecdsa-sha2-nistp256-cert-v01@openssh.com"):
        blob = wire(cert.encode(), b"\x00" * 32, b"\x03" * 32)
        check(mod.parse_key("%s %s" % (cert, base64.b64encode(blob).decode())) is None,
              "a %s certificate is refused as a key" % cert)
    check(mod.parse_key(key_line(b"ssh-dss", b"p", b"q", b"g", b"y")) is None,
          "an ssh-dss key is refused (OpenSSH 10 removed DSA)")

    # --- user.signingkey: git's literal rule, what cannot be checked --------
    check(mod._signingkey_source("key::" + ed, scratch) == ("literal", ed), "key:: is a literal")
    check(mod._signingkey_source(ed, scratch) == ("literal", ed), "a bare ssh- value is a literal")
    ec = "ecdsa-sha2-nistp256 AAAA"
    check(mod._signingkey_source(ec, scratch) == ("path", os.path.join(scratch, ec)),
          "a bare ecdsa- value is a path, as git reads it")
    spaced = " key::" + ed
    check(mod._signingkey_source(spaced, scratch) == ("path", os.path.join(scratch, spaced))
          and mod.resolve_signingkey(spaced, scratch) == (None, None)
          and not mod.signingkey_uncheckable(spaced, scratch),
          "a space-led ' key::' value is a missing path, as git reads it, never a literal")
    check(mod.signingkey_uncheckable("key::ssh-ed25519-cert-v01@openssh.com AAAA", scratch),
          "a certificate literal is not checked, never called a failure")
    private = os.path.join(scratch, "id_private")
    with open(private, "w") as fh:
        # A placeholder, not a key; the header is built in parts so the
        # secret scanners never see one in this file.
        word = "PRIVATE"
        fh.write(f"-----BEGIN OPENSSH {word} KEY-----\nx\n"
                 f"-----END OPENSSH {word} KEY-----\n")
    check(mod.resolve_signingkey(private, scratch) == (None, None) and mod.signingkey_uncheckable(private, scratch),
          "a private key path without its .pub is not checked")
    check(not mod.signingkey_uncheckable(os.path.join(scratch, "missing.pub"), scratch),
          "a missing path is not called uncheckable")

    # --- validity times: platform limits never raise ------------------------
    real_mktime = mod.time.mktime

    def overflow(tm):
        raise OverflowError("mktime argument out of range")

    mod.time.mktime = overflow
    try:
        check(mod.parse_ssh_time("20990101") is None, "an OverflowError from mktime() is a refusal")
    finally:
        mod.time.mktime = real_mktime
    check(mod.parse_ssh_time("99991231235959Z") is not None, "the largest four-digit UTC time parses")
    check(mod.parse_ssh_time("00000101Z") is None, "year 0 is refused")

    agent_out = "\n".join(["The agent has 1 identities.", "garbage", ed + " real", "", "\x1c"]) + "\n"
    stub(bindir, "ssh-add", 'printf "%%s" "%s"\n' % agent_out.replace('"', '\\"'))
    os.environ["PATH"] = bindir + os.pathsep + os.environ["PATH"]
    host = mod.Host(scratch, os.path.join(scratch, "config.local"), "INSTALLER")
    keys, err = host.agent()
    check(err is None and keys == {mod.parse_key(ed)}, "ssh-add noise lines are ignored")
    stub(bindir, "ssh-add", "sleep 5\n")
    mod.AGENT_TIMEOUT = 1
    keys, err = mod.Host(scratch, os.path.join(scratch, "c"), "I").agent()
    check(keys is None and "did not answer within 1 seconds" in (err or ""), "a hanging ssh-add times out")
    os.environ.clear()
    os.environ.update(saved)

    # --- values written into an ident line ------------------------------------
    for bad in ("me​@example.com", "me@example.com ", "me@exam\u0085ple.com",
                "me@[example].com", "me @example.com", "﻿me@example.com"):
        check(not mod.usable_principal(bad), "principal %r is refused" % bad)
    check(mod.usable_principal("zoë@example.com"), "a non-ASCII letter in a principal is accepted")
    check(not mod.usable_principal("a\udcffb@x.com"), "a principal holding a byte that is not UTF-8 is refused")
    for bad in ("Jane​Doe", "Jane Doe", "Jane\x7fDoe", "Jane <x>"):
        check(not mod.valid_name(bad), "name %r is refused" % bad)
    check(mod.valid_name('Zoë "Z" O\\Doe'), "a name with quotes and a backslash is accepted")

    # --- files: the size cap; a KRL check with no usable TMPDIR -------------
    big = os.path.join(scratch, "big")
    with open(big, "wb") as fh:
        fh.write(b"#" * (mod.MAX_FILE + 1))
    data, why = mod.read_small_file(big)
    check(data is None and why == "larger than %d bytes" % mod.MAX_FILE, "a file over MAX_FILE is refused")
    with open(big, "wb") as fh:
        fh.write(b"#" * mod.MAX_FILE)
    data, why = mod.read_small_file(big)
    check(data is not None and len(data) == mod.MAX_FILE, "a file of exactly MAX_FILE is read")
    revoked = os.path.join(scratch, "revoked")
    with open(revoked, "w") as fh:
        fh.write("# list\n%s comment\0more\n" % ed)
    keys, err = mod.load_revocation(revoked)
    check(keys is None and "line 2 holds a NUL byte - writing nothing" in (err or ""),
          "a revocation line holding a NUL byte refuses, even after the key")
    real_tempdir = mod.tempfile.tempdir
    mod.tempfile.tempdir = os.path.join(scratch, "no-such-dir")
    try:
        check(mod.krl_revokes(big, mod.parse_key(ed)) is None, "an unwritable TMPDIR makes a KRL check unknown")
    finally:
        mod.tempfile.tempdir = real_tempdir

    # --- backup_once without hard links ---------------------------------------
    target = os.path.join(scratch, "config.local")
    with open(target, "w") as fh:
        fh.write("[user]\n\temail = a@x\n")
    real_link = mod.os.link

    def no_link(src, dst):
        raise OSError(errno.EPERM, "hard links not supported")

    mod.os.link = no_link
    fd = os.open(target, os.O_RDONLY)
    try:
        mod.backup_once(target, fd, 0o600)
        with open(target + ".bak") as fh:
            check(fh.read() == "[user]\n\temail = a@x\n", "backup_once falls back to O_EXCL when link fails")
        with open(target, "w") as fh:
            fh.write("changed\n")
        mod.backup_once(target, fd, 0o600)
        with open(target + ".bak") as fh:
            check("a@x" in fh.read(), "backup_once never replaces an existing .bak")
    finally:
        os.close(fd)
        mod.os.link = real_link
    check(not [n for n in os.listdir(scratch) if n.startswith(".config.local")], "no temp file is left behind")

    # --- a write the effective config does not read back --------------------
    home = os.path.join(scratch, "home")
    gitdir = os.path.join(home, ".config", "git")
    os.makedirs(gitdir)
    with open(os.path.join(gitdir, "config"), "w") as fh:
        fh.write("[gpg]\n\tformat = ssh\n[include]\n\tpath = config.local\n")
    signers = os.path.join(gitdir, "allowed_signers")
    with open(signers, "w") as fh:
        fh.write("me@example.com %s\n" % ed)
    os.environ.update({"HOME": home, "XDG_CONFIG_HOME": os.path.join(home, ".config"),
                       "GIT_CONFIG_SYSTEM": os.devnull})
    os.environ.pop("GIT_CONFIG_GLOBAL", None)

    class Shadowed(mod.Host):
        """A later level that wins over config.local once it exists."""

        def effective(self, key, typ=None):
            if key == "tag.gpgsign" and os.path.exists(self.config_local):
                return mod.Value(0, "false", "")
            return mod.Host.effective(self, key, typ)

    host = Shadowed(home, os.path.join(gitdir, "config.local"), "INSTALLER")
    host._agent = ({mod.parse_key(ed)}, None)
    mod._captured = []
    rc = mod.identity(host, None)
    said = mod._captured
    mod._captured = None
    check(rc == 1 and any("tag.gpgsign reads 'false'" in line for line in said),
          "a key the effective config does not read back is reported, exit 1")
    os.environ.clear()
    os.environ.update(saved)

    print("%d failure(s)" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
