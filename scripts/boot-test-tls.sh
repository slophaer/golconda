# shellcheck shell=sh
# Part of scripts/boot-test, sourced by it (no processes start when sourced).
# The CA store checks (docs/design/trust.md, "3. CA store"): two HTTPS servers for the guest, one
# whose certificate chains to an anchor the test image names, one to a CA it names in both
# `anchors` and `distrust`, and the checks of the bundle and of the two fetches.
# shellcheck disable=SC2154 # the globals are set by scripts/boot-test and the other parts
# shellcheck disable=SC2034,SC2153 # and read there

# The servers are QEMU guestfwds, like the update server's (boot-test-http.sh): the guest connects
# to 169.254.169.5:443 and 169.254.169.6:443, QEMU starts the command per connection with the
# connection on its stdin and stdout, and no host port opens. The command is a TLS server over
# standard input and output (python's ssl with memory BIOs), with the certificates of
# tests/fixtures/ca-store (the CAs are named by nix/test-config.nix). The addresses are the
# fixtures' subject alternative names; .3, the DNS server of QEMU's network, is not used.
TLS_ADDR_ANCHOR=169.254.169.5
TLS_ADDR_DISTRUSTED=169.254.169.6
TLS_FIXTURES=$SCRIPT_DIR/../tests/fixtures/ca-store

# write_tls_server NAME CERT KEY: $WORKDIR/serve-NAME serves one HTTPS connection with the
# certificate and key (copied beside it) and logs to $WORKDIR/NAME.log: "handshake ok" or
# "handshake failed", then the request line, or "no request" when the client ended the connection
write_tls_server() {
  mkdir -p "$WORKDIR/$1"
  cp "$2" "$WORKDIR/$1/cert.pem"
  cp "$3" "$WORKDIR/$1/key.pem"
  cat > "$WORKDIR/serve-$1" <<'EOF'
#!/usr/bin/env python3
# Serve one HTTPS connection on stdin/stdout (QEMU guestfwd cmd:). This file is serve-NAME; it
# serves with NAME/cert.pem and NAME/key.pem beside it and logs to NAME.log.
import os, select, ssl, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = os.path.basename(__file__)[len("serve-") :]
LOG = open(os.path.join(HERE, NAME + ".log"), "a", buffering=1)


def log(msg):
    LOG.write("%s [%d] %s\n" % (time.strftime("%H:%M:%S"), os.getpid(), msg))


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_2
ctx.load_cert_chain(os.path.join(HERE, NAME, "cert.pem"), os.path.join(HERE, NAME, "key.pem"))
inb, outb = ssl.MemoryBIO(), ssl.MemoryBIO()
tls = ctx.wrap_bio(inb, outb, server_side=True)


def flush():
    data = outb.read()
    while data:
        data = data[os.write(1, data) :]


def pump():
    # more bytes from the guest into the TLS engine; the guest is gone after 10 s of silence
    if not select.select([0], [], [], 10)[0]:
        raise EOFError("no data from the guest")
    chunk = os.read(0, 65536)
    if not chunk:
        raise EOFError("the guest closed the connection")
    inb.write(chunk)


def step(fn):
    # run one TLS operation to completion, moving bytes between the BIOs and the pipes
    while True:
        try:
            result = fn()
            flush()
            return result
        except ssl.SSLWantReadError:
            flush()
            pump()
        except ssl.SSLWantWriteError:
            flush()


try:
    step(tls.do_handshake)
except (ssl.SSLError, EOFError, OSError) as e:
    flush()
    log("handshake failed: %s" % e)
    sys.exit(0)
log("handshake ok: %s" % tls.version())
request = b""
try:
    while b"\r\n\r\n" not in request:
        request += step(lambda: tls.read(4096))
except (ssl.SSLError, EOFError, OSError) as e:
    log("no request: %s" % e)
    sys.exit(0)
log('"%s"' % request.split(b"\r\n")[0].decode("latin-1"))
body = ("golconda-tls-ok " + NAME + "\n").encode()
step(lambda: tls.write(b"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n" % len(body) + body))
# close_notify, and no wait for the client's: HTTP/1.0 ends with the connection
try:
    tls.unwrap()
except (ssl.SSLError, OSError):
    pass
flush()
EOF
  chmod +x "$WORKDIR/serve-$1"
}

# probe_tls_server NAME ADDR: speak TLS to the server's command as the guest would, with python's
# client and the fixture CAs (anchor-ca and distrusted-ca) as its roots, so the host knows the
# server works before the guest asks: an HTTPS 200 with the server's marker in the body
probe_tls_server() {
  if python3 - "$WORKDIR/serve-$1" "$2" "$TLS_FIXTURES/anchor-ca.crt" "$TLS_FIXTURES/distrusted-ca.crt" <<'EOF'
import socket, ssl, subprocess, sys

server, addr, *cas = sys.argv[1:]
a, b = socket.socketpair()
proc = subprocess.Popen([server], stdin=b.fileno(), stdout=b.fileno())
b.close()
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
for ca in cas:
    ctx.load_verify_locations(ca)
tls = ctx.wrap_socket(a, server_hostname=addr)
tls.sendall(b"GET /probe HTTP/1.0\r\n\r\n")
data = b""
while chunk := tls.recv(4096):
    data += chunk
proc.wait(timeout=10)
if not data.startswith(b"HTTP/1.0 200 ") or b"golconda-tls-ok" not in data:
    sys.exit("unexpected answer: %r" % data)
EOF
  then
    : > "$WORKDIR/$1.log"
  else
    echo "Error: the TLS server $1 does not answer on the host; its log:" >&2
    cat "$WORKDIR/$1.log" >&2 || true
    return 1
  fi
}

# start_tls_servers: the two servers, proved on the host
start_tls_servers() {
  write_tls_server tls-anchor "$TLS_FIXTURES/server-anchor.crt" "$TLS_FIXTURES/server-anchor.key"
  write_tls_server tls-distrusted "$TLS_FIXTURES/server-distrusted.crt" "$TLS_FIXTURES/server-distrusted.key"
  probe_tls_server tls-anchor "$TLS_ADDR_ANCHOR" || return 1
  probe_tls_server tls-distrusted "$TLS_ADDR_DISTRUSTED" || return 1
  echo "Serving HTTPS to the guest as https://$TLS_ADDR_ANCHOR/ (the added anchor) and https://$TLS_ADDR_DISTRUSTED/ (a distrusted CA); QEMU guestfwd, no host port; logs $WORKDIR/tls-*.log"
}

# fetch_tls ADDR: fetch https://ADDR/ on the guest with the image's own client, systemd-pull (libcurl
# on OpenSSL, reading /etc/ssl/certs/ca-certificates.crt as built in), to a file under /run. The
# output is the client's words, then "rc=N" and the size of the file (or "none")
fetch_tls() {
  guest "/usr/lib/systemd/systemd-pull raw --direct --verify=no https://$1/ca-store-probe /run/ca-store-probe 2>&1; echo rc=\$?; (wc -c < /run/ca-store-probe || echo none) 2>/dev/null; rm -f /run/ca-store-probe" 2>&1
}

# check_ca_store: the image's CA bundle is the one the options of /trust describe, read where the
# image's clients read it, and a client uses it
check_ca_store() {
  echo ""
  echo "=== /trust: the CA store ==="

  # the two paths OpenSSL and curl read are links to the one file in /usr
  RC=0
  for p in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt; do
    T=$(guest readlink "$p" 2>&1) || true
    echo "$p -> $T"
    [ "$T" = /usr/share/ca-certificates/ca-bundle.crt ] || RC=1
  done
  guest ls /etc/ssl 2>&1 || true
  verdict "ca-store-links (/etc/ssl/cert.pem and /etc/ssl/certs/ca-certificates.crt link /usr/share/ca-certificates/ca-bundle.crt)" $RC

  # the bundle the guest reads: the added anchor in, the anchor that is also distrusted out, the
  # distrusted Mozilla root out, the other roots in
  RC=0
  guest cat /etc/ssl/cert.pem > "$WORKDIR/guest-ca-bundle.crt" 2>/dev/null || RC=1
  python3 - "$WORKDIR/guest-ca-bundle.crt" "$TLS_FIXTURES" <<'EOF' || RC=1
import os, re, sys

bundle, fixtures = sys.argv[1:3]
BLOCK = re.compile(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", re.S)


def blocks(path):
    with open(path) as f:
        return [re.sub(r"\s+", "", b) for b in BLOCK.findall(f.read())]


got = blocks(bundle)
(anchor,) = blocks(os.path.join(fixtures, "anchor-ca.crt"))
(distrusted,) = blocks(os.path.join(fixtures, "distrusted-ca.crt"))
(root,) = blocks(os.path.join(fixtures, "mozilla-root.crt"))
print("%d certificates in the guest's bundle" % len(got))
ok = True
for what, cond in [
    ("Mozilla's roots are there (more than 100)", len(got) > 100),
    ("the added anchor is in", anchor in got),
    ("the anchor that is also distrusted is out", distrusted not in got),
    ("the distrusted Mozilla root (COMODO ECC) is out", root not in got),
    ("no certificate twice", len(got) == len(set(got))),
]:
    print(("ok: " if cond else "NOT ok: ") + what)
    ok = ok and cond
sys.exit(0 if ok else 1)
EOF
  verdict "ca-bundle-content (the guest's bundle has Mozilla's roots and the added anchor, not the distrusted ones)" $RC

  # an HTTPS fetch to a server whose certificate chains to the added anchor works
  RC=0
  A=$(fetch_tls "$TLS_ADDR_ANCHOR") || true
  echo "systemd-pull https://$TLS_ADDR_ANCHOR/: $A"
  echo "$A" | grep -q '^rc=0$' || RC=1
  # the marker's size: "golconda-tls-ok tls-anchor" and a newline
  echo "$A" | grep -q '^27$' || RC=1
  grep -q 'handshake ok' "$WORKDIR/tls-anchor.log" 2>/dev/null || RC=1
  verdict "tls-anchor-trusted (https to a server certified by the added anchor succeeds)" $RC

  # one that chains to a CA in `anchors` and `distrust` fails on the certificate: the client says
  # so, nothing is stored, and the server got a handshake and no request
  RC=0
  D=$(fetch_tls "$TLS_ADDR_DISTRUSTED") || true
  echo "systemd-pull https://$TLS_ADDR_DISTRUSTED/: $D"
  echo "$D" | grep -q '^rc=0$' && RC=1
  echo "$D" | grep -qi 'certificate' || RC=1
  echo "$D" | grep -q '^none$' || RC=1
  # TLS 1.3: the server's side of the handshake is done when it has sent its flight, so its log
  # says "handshake ok" (or "handshake failed" when the alert came first), and then the guest ends
  # the connection without a request
  cat "$WORKDIR/tls-distrusted.log" 2>/dev/null || true
  grep -q 'handshake' "$WORKDIR/tls-distrusted.log" 2>/dev/null || RC=1
  grep -q '"GET ' "$WORKDIR/tls-distrusted.log" 2>/dev/null && RC=1
  verdict "tls-distrusted-refused (https to a server certified by a distrusted CA fails on the certificate)" $RC
}
