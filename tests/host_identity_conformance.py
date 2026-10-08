# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

#
# Conformance runner for lib/host_identity.py's allowed-signers matcher,
# called from tests/host_identity_test.sh as
#   python3 -I -B tests/host_identity_conformance.py \
#     MODULE VECTORS PUBKEY [SIG MSG]
# For every vector (tests/fixtures/allowed_signers/verify-git.txt) it asks the
# module what `ssh-keygen -Y verify -n git -I a@x` would decide, and compares
# with the recorded verdict. Given SIG and MSG (a signature of MSG by PUBKEY's
# private half, namespace git), it also asks ssh-keygen itself, so the recorded
# verdicts are proven against OpenSSH on every run, not only when written. The
# ECDSA and RSA vectors use keys this runner generates and signatures it makes
# with those keys' files, never through an ssh-agent.
# With the oracle it then checks gpg.ssh.revocationFile handling the same way
# (`ssh-keygen -Y verify -r`): flat key lists and a KRL, built here; and the
# validity-time parser against ssh-keygen's own (a certificate signed with
# `-V TIME:forever`, read back with `ssh-keygen -L`), in the time zone the
# caller sets: tests/host_identity_test.sh runs this file under several.
# Called as
#   python3 -I -B tests/host_identity_conformance.py --differential \
#     MODULE PUBKEY SIG MSG
# it runs the generated differential leg instead (differential(), below).
# A separate .py file rather than a heredoc in the .sh test, the same reason
# tests/release_workflow_check.py gives: bin/check-patterns scans tests/*.sh by
# content.
# Exit status: 0 every vector agrees; 1 a disagreement (each one printed).

import base64
import calendar
import importlib.util
import os
import random
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time

# Validity times for the certificate oracle: local and UTC, summer and winter
# (tm_isdst), a normalised date, a leap-second field, 1970-01-01 local (before
# the epoch east of UTC, after it west of UTC), and times ssh-keygen refuses.
# Never a seconds field of 61, which glibc's strptime() takes and macOS's
# refuses.
TIMES = [
    "20990701", "20990101", "209907011230", "20990701123045", "20990701Z",
    "20990701z", "20990701UTC", "20990701utc", "20000230", "20990701235960",
    "19700101", "19700102", "19691231", "20001301", "20000132", "200001012400",
    "200001011260", "2000010", "20000101Zz", "UTC", "Z",
]


def load(path):
    # Never write a __pycache__ beside lib/: check-patterns reads that tree.
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("host_identity", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def unescape(text):
    """The fixture's one escape, `\\xHH`, to bytes; everything else verbatim."""
    raw = text.encode("utf-8")
    return re.sub(rb"\\x([0-9a-fA-F]{2})", lambda m: bytes([int(m.group(1), 16)]), raw)


def agentless_env():
    env = dict(os.environ)
    env.pop("SSH_AUTH_SOCK", None)  # sign from the file, never an agent
    env.pop("SSH_AGENT_PID", None)
    return env


def gen_key(scratch, name, args, msg):
    """(the `<type> <base64>` of a fresh key, the path of its signature of a
    copy of MSG, or None without MSG). ARGS are ssh-keygen's -t/-b."""
    path = os.path.join(scratch, name)
    env = agentless_env()
    subprocess.run(["ssh-keygen", "-q"] + args + ["-N", "", "-C", name, "-f", path],
                   check=True, stdin=subprocess.DEVNULL, env=env)
    with open(path + ".pub") as fh:
        key = " ".join(fh.read().split()[:2])
    sig = None
    if msg is not None:
        copy = os.path.join(scratch, name + "_msg")
        shutil.copyfile(msg, copy)
        subprocess.run(["ssh-keygen", "-q", "-Y", "sign", "-n", "git", "-f", path, copy],
                       check=True, stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
        sig = copy + ".sig"
    return key, sig


def ecdsa_key(scratch, msg):
    """An ECDSA key (gen_key()): its blob ends in two spill bits, which
    ed25519's never has, so a non-canonical spelling can be written."""
    return gen_key(scratch, "ec", ["-t", "ecdsa", "-b", "256"], msg)


def spill(key):
    """KEY with a spill bit set in the base64 character before its padding:
    the same blob to a lenient decoder, a refusal to b64_pton()."""
    keytype, b64 = key.split(" ")
    assert b64.endswith("=") and not b64.endswith("=="), b64
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    last = alphabet[alphabet.index(b64[-2]) | 1]
    return "%s %s%s=" % (keytype, b64[:-2], last)


def substitute(raw, key, ec_key, rsa_key):
    """(line bytes, the key it names) with the placeholders filled in."""
    keytype, b64 = key.split(" ")
    named = ec_key if b"@ECKEY" in raw else rsa_key if b"@RSA" in raw else key
    rsa_b64 = rsa_key.split(" ")[1]
    line = (raw.replace(b"@RSA256@", ("rsa-sha2-256 " + rsa_b64).encode())
            .replace(b"@RSA512@", ("rsa-sha2-512 " + rsa_b64).encode())
            .replace(b"@KEYHEAD@", (keytype + " " + b64[:20]).encode())
            .replace(b"@KEYTAIL@", b64[20:].encode())
            .replace(b"@KEY@", key.encode())
            .replace(b"@ECKEYSPILL@", spill(ec_key).encode())
            .replace(b"@ECKEY@", ec_key.encode()))
    return line, named


def unclear(mod, line, key):
    """True when the module reads LINE as malformed and still names KEY in
    it, so the writing modes would write nothing for that key."""
    _, bad = mod.parse_allowed_signers(line)
    return bad == [1] and mod.parse_key(key) in mod.keys_named(mod.decode_lines(line)[0])


def module_verdict(mod, line, now, revoked=None):
    entries, _ = mod.parse_allowed_signers(line)
    for e in entries:
        if mod.entry_verifies(e, "a@x", now) and not (revoked and e.key in revoked):
            return "OK"
    return "REJECT"


def oracle_verdict(line, sig, msg, scratch, revocation=None):
    one = os.path.join(scratch, "one")
    with open(one, "wb") as fh:
        fh.write(line + b"\n")
    args = ["ssh-keygen", "-Y", "verify", "-n", "git", "-I", "a@x", "-s", sig, "-f", one]
    if revocation:
        args += ["-r", revocation]
    with open(msg, "rb") as data:
        p = subprocess.run(args, stdin=data, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return "OK" if p.returncode == 0 else "REJECT"


def revocation_cases(mod, key_line, pub, sig, msg, scratch):
    """Each case: the module's reading of a revocation file must give the
    same verdict as `ssh-keygen -Y verify -r` for a line that verifies."""
    other = os.path.join(scratch, "other")
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", other],
                   check=True, stdin=subprocess.DEVNULL)
    with open(pub) as fh:
        mine = fh.read()
    with open(other + ".pub") as fh:
        theirs = fh.read()
    files = {
        "empty": b"",
        "comment only": b"# nothing revoked\n",
        "another key": theirs.encode(),
        "this key": mine.encode(),
        "this key, no comment": (" ".join(mine.split()[:2]) + "\n").encode(),
        "this key after a comment and a blank": ("# c\n\n" + mine).encode(),
        "a line that is not a key": ("garbage\n" + theirs).encode(),
        "a line holding a carriage return": ("\r\n" + theirs).encode(),
        "a carriage return after a tab": ("\t\r\n" + theirs).encode(),
        "this key with CRLF line ends": ("# c\r\n" + mine.rstrip("\n") + "\r\n").encode(),
        "a comment after spaces": ("   # c\n" + mine).encode(),
    }
    failures = 0
    for name, data in sorted(files.items()):
        path = os.path.join(scratch, "rev")
        with open(path, "wb") as fh:
            fh.write(data)
        failures += compare_revocation(mod, name, path, key_line, sig, msg, scratch)
    for name, keyfile in (("KRL with this key", pub), ("KRL with another key", other + ".pub")):
        path = os.path.join(scratch, "krl")
        if os.path.exists(path):
            os.unlink(path)
        subprocess.run(["ssh-keygen", "-q", "-k", "-f", path, keyfile], check=True, stdin=subprocess.DEVNULL)
        failures += compare_revocation(mod, name, path, key_line, sig, msg, scratch)
    return failures


def compare_revocation(mod, name, path, key_line, sig, msg, scratch):
    plain, err = mod.load_revocation(path)
    entries, _ = mod.parse_allowed_signers(key_line)
    key = entries[0].key
    if err:
        got = "REJECT"
    elif plain is None:
        got = "REJECT" if mod.krl_revokes(path, key) is not False else "OK"
    else:
        got = module_verdict(mod, key_line, time.time(), plain)
    ssh = oracle_verdict(key_line, sig, msg, scratch, path)
    if got != ssh:
        print("revocation [%s]: module says %s, ssh-keygen says %s" % (name, got, ssh))
        return 1
    return 0


def time_cases(mod, pub, scratch):
    """parse_ssh_time() must read every TIMES value as ssh-keygen does: the
    same epoch, or a refusal on both sides."""
    ca = os.path.join(scratch, "ca")
    if not os.path.exists(ca):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", ca],
                       check=True, stdin=subprocess.DEVNULL)
    key = os.path.join(scratch, "timed.pub")
    shutil.copyfile(pub, key)
    cert = os.path.join(scratch, "timed-cert.pub")
    failures = 0
    for value in TIMES:
        if os.path.exists(cert):
            os.unlink(cert)
        subprocess.run(["ssh-keygen", "-q", "-s", ca, "-I", "t", "-V", value + ":forever", key],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ssh = None
        if os.path.exists(cert):
            env = dict(os.environ, TZ="UTC")
            out = subprocess.run(["ssh-keygen", "-L", "-f", cert], env=env, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, universal_newlines=True).stdout
            m = re.search(r"Valid: (?:after|from) (\S+)", out)
            if m is None and re.search(r"Valid: forever", out):
                ssh = 0  # the epoch itself: no lower bound to print
            elif m is None:
                print("time [%s]: cannot read the certificate's validity: %r" % (value, out))
                failures += 1
                continue
            else:
                ssh = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S"))
        got = mod.parse_ssh_time(value)
        if got != ssh:
            print("time [%s] in TZ=%s: module reads %r, ssh-keygen reads %r"
                  % (value, os.environ.get("TZ", ""), got, ssh))
            failures += 1
    return failures


# --- the generated differential leg ------------------------------------------
# A fixed corpus, generated (seeded, so every run and every platform reads the
# same lines), of single allowed-signers lines that name a key K whose
# signature the oracle checks. Two outcomes are failures:
#   BYPASS      ssh-keygen accepts the line for K, and the module neither
#               accepts it nor names K in it as a malformed line (the step
#               could then write another key while K is valid);
#   OVERACCEPT  the module accepts the line for K and ssh-keygen refuses it.
# A line the module refuses as malformed while naming K is a strict refusal
# (the step writes nothing), never a failure: on glibc a seconds field of 61
# lands there. Then the same two checks per key spelling, with `ssh-keygen -l`
# as the oracle, which also covers the security-key types no software key can
# sign for.
# The leg also checks itself, so that it cannot pass by checking nothing: the
# corpus and the spellings must reach their floors, the oracle and the module
# must meet in each bucket named in BUCKETS (agreement, and a strict refusal
# on both sides of the oracle), and the two classifiers must flag the cases
# self_check() hands them.
SEED = 20261006
MIN_LINES = 1500
MIN_SPELLINGS = 40
BUCKETS = (("OK", "OK"), ("OK", "UNCLEAR"), ("REJECT", "UNCLEAR"))
V61 = 'valid-before="20991231235961"'
POOL = ["\0", "\r", "\f", "\v", "\t", " ", '"', ",", "=", "\\", "\x1c", "#", "!", "*", "a"]


def corpus(key):
    """The generated lines (str, one per case) for KEY, `<type> <base64>`."""
    keytype, b64 = key.split(" ")
    kb = key
    p = "a@x "
    lines = []
    names = [keytype, keytype.upper(), keytype.lower(), "ED25519", "RSA", "ECDSA", "rsa-sha2-256",
             "rsa-sha2-512", "RSA-SHA2-256", "ssh-dss", keytype + "-cert-v01@openssh.com"]
    for name in names:
        lines.append(p + name + " " + b64)
        lines.append(p + V61 + " " + name + " " + b64)
    base = p + kb
    step = max(1, len(base) // 24)
    for i in range(0, len(base) + 1, step):
        lines.append(base[:i] + "\0" + base[i:])
    lines += [p + kb + " \0x", p + kb + " com\0ment", p + 'namespaces="g\0it" ' + kb,
              "a@x,\0b@y " + kb, "\0" + base, "#\0" + base]
    for sep in ["\t", "  ", " \t ", "\r", "\v", "\f", "\x1c", " "]:
        lines += ["a@x" + sep + kb, p + keytype + sep + b64, p + 'namespaces="git"' + sep + kb,
                  p + V61 + " " + keytype + sep + b64]
    for tail in [" c", "\tc", "\fc", "\vc", "\rc", ",c", '"c', "=", "=="]:
        lines += [p + kb + tail, p + V61 + " " + kb + tail]
    for glue in ['"a@x"', "a@x\r", 'a@x,"b@y"', '"a@x" "', "a@x x"]:
        lines.append(glue + kb)
    lines.append(p + 'namespaces="git"' + kb)
    for ws in ["\v", "\f", "\r", "\f\v\r"]:
        for pos in sorted(set([0, 1, 4, len(b64) // 2, len(b64) - 1, len(b64)])):
            lines.append(p + keytype + " " + b64[:pos] + ws + b64[pos:])
            lines.append(p + V61 + " " + keytype + " " + b64[:pos] + ws + b64[pos:])
    rng = random.Random("%d %s" % (SEED, keytype))
    bases = [base, p + 'namespaces="git" ' + kb, p + V61 + " " + kb, '"a@x" ' + kb, "a@x,b@y " + kb + " c"]
    for _ in range(400):
        line = rng.choice(bases)
        for _ in range(rng.randint(1, 3)):
            i = rng.randint(0, len(line))
            line = line[:i] + rng.choice(POOL) + line[i:]
        lines.append(line)
    return lines


def module_reads(mod, line, key, now):
    """OK (the module accepts LINE for KEY), UNCLEAR (malformed, KEY named)
    or MISS."""
    data = line.encode("utf-8", "surrogateescape")
    entries, bad = mod.parse_allowed_signers(data)
    for e in entries:
        if e.key == key and mod.entry_verifies(e, "a@x", now):
            return "OK"
    if bad and key in mod.keys_named(mod.decode_lines(data)[0]):
        return "UNCLEAR"
    return "MISS"


def sk_keys(ed_key, ec_key):
    """Security-key public keys built from a software key's material: the
    blob is all ssh-keygen -l reads, and no software key can sign as one."""
    def wire(*parts):
        return b"".join(struct.pack(">I", len(x)) + x for x in parts)
    ed = base64.b64decode(ed_key.split(" ")[1])[-32:]
    point = base64.b64decode(ec_key.split(" ")[1])[4 + 19 + 4 + 8 + 4:]
    out = []
    for t, blob in (("sk-ssh-ed25519@openssh.com", wire(b"sk-ssh-ed25519@openssh.com", ed, b"ssh:")),
                    ("sk-ecdsa-sha2-nistp256@openssh.com",
                     wire(b"sk-ecdsa-sha2-nistp256@openssh.com", b"nistp256", point, b"ssh:"))):
        out.append("%s %s" % (t, base64.b64encode(blob).decode()))
    return out


def spellings(key):
    keytype, b64 = key.split(" ")
    out = [key, keytype + " " + b64[:10] + "\f" + b64[10:], keytype + " " + b64[:10] + "\v" + b64[10:],
           key + "\r", keytype.upper() + " " + b64, key + "=", keytype + " " + b64[:10] + "\x1c" + b64[10:],
           "rsa-sha2-256 " + b64, "rsa-sha2-512 " + b64]
    if b64.endswith("=") and not b64.endswith("=="):
        out.append(spill(key))
    return out


def line_failure(ssh, got):
    """BYPASS, OVERACCEPT or None for the oracle's and the module's verdicts
    on one line."""
    if ssh == "OK" and got == "MISS":
        return "BYPASS"
    if ssh == "REJECT" and got == "OK":
        return "OVERACCEPT"
    return None


def key_failure(ssh, got, want, named):
    """KEY OVERACCEPT, KEY BYPASS or None for one spelling: SSH is the
    fingerprint `ssh-keygen -l` prints (or None), GOT the one the module
    reads (or None), WANT the key's own, NAMED whether keys_named() finds
    the key in a malformed line holding the spelling."""
    if got is not None and got != ssh:
        return "KEY OVERACCEPT"
    if ssh is not None and ssh == want and got != want and not named:
        return "KEY BYPASS"
    return None


def judge_lines(rows):
    """Failure messages for (label, oracle verdict, module verdict) rows."""
    out = []
    for label, ssh, got in rows:
        verdict = line_failure(ssh, got)
        if verdict:
            out.append("%s %s" % (verdict, label))
    return out


def judge_keys(rows):
    """Failure messages for (label, ssh, got, want, named) key_failure() rows."""
    out = []
    for label, ssh, got, want, named in rows:
        verdict = key_failure(ssh, got, want, named)
        if verdict:
            out.append("%s %s: module reads %s, ssh-keygen -l reads %s" % (verdict, label, got, ssh))
    return out


def self_check():
    """Failures of the classifiers, and of the two judges the leg runs its
    rows through, on cases whose answer is known."""
    cases = [
        (line_failure("OK", "MISS"), "BYPASS"), (line_failure("REJECT", "OK"), "OVERACCEPT"),
        (line_failure("OK", "UNCLEAR"), None), (line_failure("REJECT", "MISS"), None),
        (line_failure("OK", "OK"), None),
        (key_failure(None, "fp", "fp", False), "KEY OVERACCEPT"),
        (key_failure("other", "fp", "fp", False), "KEY OVERACCEPT"),
        (key_failure("fp", None, "fp", False), "KEY BYPASS"),
        (key_failure("fp", None, "fp", True), None), (key_failure("fp", "fp", "fp", False), None),
        (key_failure(None, None, "fp", False), None),
    ]
    out = ["self-check: case %d gives %s, want %s" % (n, got, want)
           for n, (got, want) in enumerate(cases) if got != want]
    lines = judge_lines([("a", "OK", "MISS"), ("b", "REJECT", "OK"), ("c", "OK", "OK")])
    if [x.split(" ")[0] for x in lines] != ["BYPASS", "OVERACCEPT"]:
        out.append("self-check: judge_lines flags %r" % lines)
    keys = judge_keys([("a", None, "fp", "fp", False), ("b", "fp", None, "fp", False), ("c", "fp", "fp", "fp", False)])
    if [" ".join(x.split(" ")[:2]) for x in keys] != ["KEY OVERACCEPT", "KEY BYPASS"]:
        out.append("self-check: judge_keys flags %r" % keys)
    return out


def key_reads(mod, key, scratch):
    """judge_keys() rows for KEY: what ssh-keygen -l reads of each
    spelling, against parse_key() and keys_named()."""
    want = mod.parse_key(key)
    path = os.path.join(scratch, "spelled.pub")
    rows = []
    for spelled in spellings(key):
        with open(path, "wb") as fh:
            fh.write((spelled + " c\n").encode("utf-8", "surrogateescape"))
        p = subprocess.run(["ssh-keygen", "-l", "-f", path], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, universal_newlines=True, env=agentless_env())
        ssh = p.stdout.split()[1] if p.returncode == 0 and len(p.stdout.split()) > 1 else None
        got = mod.parse_key(spelled)
        named = want in mod.keys_named("a@x %s %s" % (V61, spelled))
        rows.append((repr(spelled), ssh, mod.fingerprint(got) if got else None, mod.fingerprint(want), named))
    return rows


def differential(mod, ed_key, sig, msg, scratch):
    """Run the generated leg; print each failure; return their number."""
    start = time.time()
    ec_key, ec_sig = ecdsa_key(scratch, msg)
    rsa_key, rsa_sig = gen_key(scratch, "rsa", ["-t", "rsa", "-b", "2048"], msg)
    now = time.time()
    failures = self_check()
    rows = []
    for key, ksig in ((ed_key, sig), (ec_key, ec_sig), (rsa_key, rsa_sig)):
        want = mod.parse_key(key)
        for line in corpus(key):
            data = line.encode("utf-8", "surrogateescape")
            ssh = oracle_verdict(data, ksig, msg, scratch)
            got = module_reads(mod, line, want, now)
            rows.append(("%s: %r" % (key.split(" ")[0], line), ssh, got))
    lines = len(rows)
    # A canary row of each kind rides through the same judging as the real
    # ones and must come back flagged, so a result that is dropped fails.
    failures += judge_lines(rows + [("canary", "OK", "MISS")])
    counts = {}
    for _, ssh, got in rows:
        counts[(ssh, got)] = counts.get((ssh, got), 0) + 1
    key_rows = []
    for key in [ed_key, ec_key, rsa_key] + sk_keys(ed_key, ec_key):
        key_rows += key_reads(mod, key, scratch)
    spelled = len(key_rows)
    failures += judge_keys(key_rows + [("canary", "fp", None, "fp", False)])
    for canary in ("BYPASS canary", "KEY BYPASS canary: module reads None, ssh-keygen -l reads fp"):
        if canary in failures:
            failures.remove(canary)
        else:
            failures.append("the canary row [%s] was not flagged" % canary)
    if lines < MIN_LINES:
        failures.append("only %d lines generated, fewer than %d" % (lines, MIN_LINES))
    if spelled < MIN_SPELLINGS:
        failures.append("only %d key spellings read, fewer than %d" % (spelled, MIN_SPELLINGS))
    for bucket in BUCKETS:
        if not counts.get(bucket):
            failures.append("no line where ssh-keygen says %s and the module %s" % bucket)
    for f in failures:
        print(f)
    print("differential: %d lines, %d key spellings, %d failure(s), %.1f s; %s"
          % (lines, spelled, len(failures), time.time() - start,
             ", ".join("%s/%s %d" % (k[0], k[1], v) for k, v in sorted(counts.items()))))
    return len(failures)


def main(argv):
    if len(argv) == 5 and argv[0] == "--differential":
        mod = load(argv[1])
        with open(argv[2]) as fh:
            key = " ".join(fh.read().split()[:2])
        with tempfile.TemporaryDirectory() as scratch:
            return 1 if differential(mod, key, argv[3], argv[4], scratch) else 0
    if len(argv) not in (3, 5):
        print("usage: host_identity_conformance.py MODULE VECTORS PUBKEY [SIG MSG]", file=sys.stderr)
        return 2
    mod = load(argv[0])
    with open(argv[2]) as fh:
        key = " ".join(fh.read().split()[:2])
    oracle = argv[3:5]
    now = time.time()
    failures = 0
    checked = 0
    with tempfile.TemporaryDirectory() as scratch, open(argv[1], encoding="utf-8") as fh:
        ec_key, ec_sig = ecdsa_key(scratch, oracle[1] if oracle else None)
        rsa_key, rsa_sig = gen_key(scratch, "rsa", ["-t", "rsa", "-b", "2048"], oracle[1] if oracle else None)
        for n, raw in enumerate(fh, 1):
            raw = raw.rstrip("\n")
            if not raw or raw.startswith("#"):
                continue
            want, tab, text = raw.partition("\t")
            if not tab or want not in ("OK", "REJECT", "UNCLEAR"):
                print("vector line %d: malformed" % n)
                failures += 1
                continue
            line, named = substitute(unescape(text), key, ec_key, rsa_key)
            # UNCLEAR: ssh-keygen accepts the line, and the module refuses it
            # as malformed while naming its key, which writes nothing.
            got = module_verdict(mod, line, now)
            if want == "UNCLEAR":
                if got != "REJECT" or not unclear(mod, line, named):
                    print("vector line %d: module says %s and does not name the key of a malformed line: %s"
                          % (n, got, raw))
                    failures += 1
            elif got != want:
                print("vector line %d: module says %s, recorded %s: %s" % (n, got, want, raw))
                failures += 1
            if oracle:
                sig = {ec_key: ec_sig, rsa_key: rsa_sig}.get(named, oracle[0])
                ssh = oracle_verdict(line, sig, oracle[1], scratch)
                if ssh != {"UNCLEAR": "OK"}.get(want, want):
                    print("vector line %d: ssh-keygen says %s, recorded %s: %s" % (n, ssh, want, raw))
                    failures += 1
            checked += 1
        if oracle:
            failures += revocation_cases(mod, b"a@x " + key.encode(), argv[2], oracle[0], oracle[1], scratch)
            failures += time_cases(mod, argv[2], scratch)
    if checked < 60:
        print("only %d vectors read (fixture rot?)" % checked)
        return 1
    print("%d vectors, %s" % (checked, "oracle checked, revocation and times checked" if oracle else "no oracle"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
