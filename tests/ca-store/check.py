#!/usr/bin/env python3
"""checks.ca-store: the CA bundle built from /trust's options, read as OpenSSL reads it.

usage: check.py FIXTURES CACERT_BUNDLE BUNDLE OPENSSL

BUNDLE is the ca-bundle package built from the anchors and the distrust list that
nix/checks.nix names (the fixtures' anchor-ca, distrusted-ca; distrusted-ca and
mozilla-root). Each check prints PASS or FAIL with its name; the exit status is 1 on any FAIL.
"""
import os
import re
import subprocess
import sys

fixtures, cacert, bundle, openssl = sys.argv[1:5]
BLOCK = re.compile(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", re.S)


def blocks(path):
    with open(path) as f:
        return [re.sub(r"\s+", "", b) for b in BLOCK.findall(f.read())]


def one(name):
    (b,) = blocks(os.path.join(fixtures, name))
    return b


failed = 0


def check(name, ok):
    global failed
    print(("PASS: " if ok else "FAIL: ") + name)
    if not ok:
        failed += 1


mozilla = blocks(cacert)
got = blocks(bundle)
anchor, distrusted, root = one("anchor-ca.crt"), one("distrusted-ca.crt"), one("mozilla-root.crt")

check("the Mozilla root to distrust is in cacert (the test is not vacuous)", root in mozilla)
check("an added anchor is in the bundle", anchor in got)
check("a distrusted Mozilla root is not in the bundle", root not in got)
check("a certificate that is an anchor and distrusted is not in the bundle (distrust wins)", distrusted not in got)
check("every other Mozilla root is in the bundle", all(m in got for m in mozilla if m != root))
check(
    "the bundle is exactly the roots, plus the anchor, minus the distrusted ones",
    set(got) == (set(mozilla) | {anchor}) - {root, distrusted},
)
check("no certificate twice", len(got) == len(set(got)))


def verify(leaf):
    env = dict(os.environ, OPENSSL_CONF="/dev/null")
    r = subprocess.run(
        [openssl, "verify", "-purpose", "sslserver", "-CAfile", bundle, os.path.join(fixtures, leaf)],
        env=env, capture_output=True, text=True,
    )
    return r.returncode == 0


# OpenSSL reads the bundle as a client does: with the file as its only trust store
check("OpenSSL verifies a server certificate that chains to the added anchor", verify("server-anchor.crt"))
check("OpenSSL refuses one that chains to the distrusted anchor", not verify("server-distrusted.crt"))
sys.exit(1 if failed else 0)
