# shellcheck shell=sh
# Part of scripts/boot-test, sourced by it (no processes start when sourced).
# The update server: the release directory over HTTP for --next, as a QEMU guest forward; the fake
# IMDS endpoint (--imds).
# shellcheck disable=SC2154 # the globals are set by scripts/boot-test and the other parts
# shellcheck disable=SC2034,SC2153 # and read there

# --- the release HTTP server (--next) ---
# The image's url-file source is http://$UPDATE_ADDR:$HTTP_PORT/ (169.254.169.2:8074 in the test
# image), and --imds serves Hetzner's metadata at http://169.254.169.254/. The harness opens no host port for
# either: QEMU's user network forwards the guest's connections to such an address to a command
# (start_qemu: guestfwd=tcp:$UPDATE_ADDR:$HTTP_PORT-cmd:$WORKDIR/serve-http), which QEMU starts once
# per connection with the connection on its stdin and stdout. Two runs on one host both serve
# "8074" to their own guest and share nothing. The command is the standard library's
# SimpleHTTPRequestHandler over stdio, so the guest sees the same server `python3 -m http.server`
# was (HTTP/1.0, one request per connection, no ranges).

# write_http_server NAME: $WORKDIR/serve-NAME serves $WORKDIR/NAME and logs to $WORKDIR/NAME.log
write_http_server() {
  cat > "$WORKDIR/serve-$1" <<'EOF'
#!/usr/bin/env python3
# Serve one HTTP connection on stdin/stdout (QEMU guestfwd cmd:). This file is serve-NAME; it
# serves the directory NAME beside it and logs to NAME.log.
import http.server, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = os.path.basename(__file__)[len("serve-") :]
LOG = open(os.path.join(HERE, NAME + ".log"), "a", buffering=1)


class Handler(http.server.SimpleHTTPRequestHandler):
    def setup(self):
        self.rfile = sys.stdin.buffer
        self.wfile = sys.stdout.buffer

    def finish(self):
        self.wfile.flush()

    def log_message(self, fmt, *args):
        LOG.write("%s [%d] %s\n" % (self.log_date_time_string(), os.getpid(), fmt % args))


Handler(None, ("guest", 0), None, directory=os.path.join(HERE, NAME))
EOF
  chmod +x "$WORKDIR/serve-$1"
}

# probe_http_server NAME PATH: ask the server the guest's first question; a 200, or an error
probe_http_server() {
  ANSWER=$(printf 'GET %s HTTP/1.0\r\n\r\n' "$2" | "$WORKDIR/serve-$1" 2>"$WORKDIR/serve-$1.err" | head -n 1) || true
  case $ANSWER in
    "HTTP/1."*" 200 "*) return 0 ;;
  esac
  echo "Error: the $1 server answered '$ANSWER' to GET $2; its stderr:" >&2
  cat "$WORKDIR/serve-$1.err" >&2 || true
  return 1
}

# start_http_server: copy the release into $WORKDIR/http, write the server, and prove it answers
# on the host (QEMU starts it later, for each guest connection)
start_http_server() {
  HTTP_ROOT="$WORKDIR/http"
  HTTP_LOG="$WORKDIR/http.log"
  mkdir -p "$HTTP_ROOT"
  : > "$HTTP_LOG"
  # The release directory holds symlinks into the store, and a chroot store's /nix/store is not
  # the host's: resolve each file the way the rest of this script does, then copy the bytes.
  for f in "$NEXT_RELEASE"/*; do
    if ! cp "$(real_path "$f")" "$HTTP_ROOT/$(basename "$f")"; then
      echo "Error: cannot copy $f into $HTTP_ROOT" >&2
      return 1
    fi
  done

  # the negative control of the signed index: one byte more in SHA256SUMS, the signature unchanged
  if [ "$TAMPER_INDEX" = 1 ]; then
    chmod u+w "$HTTP_ROOT/SHA256SUMS"
    printf '\n' >> "$HTTP_ROOT/SHA256SUMS"
    echo "--tamper-index: served SHA256SUMS has one byte more than its signature covers"
  fi

  write_http_server http
  probe_http_server http /SHA256SUMS || return 1
  : > "$HTTP_LOG"

  echo "Serving $NEXT_RELEASE to the guest as http://$UPDATE_ADDR:$HTTP_PORT/ (QEMU guestfwd, no host port; log $HTTP_LOG)"
}

# --- the fake IMDS endpoint (--imds) ---
# start_imds_server: what Hetzner Cloud's metadata service answers, at its own address and paths:
# QEMU's user network is $GUEST_NET, so http://$IMDS_ADDR/ is on the guest's link
# (a guestfwd, like the update server's: no host port), and the guest finds the endpoint by hwdb
# alone, as on Hetzner: base URL http://$IMDS_ADDR/hetzner/v1, the host name and the other keys under
# /metadata/, the user data at /userdata. /metadata/public-keys is Hetzner's JSON array of the
# project's keys (a key nothing logs in with: systemd-imds cannot read the array). The user data
# lists four credentials: imds-canary; login.motd, which tmpfiles writes to /etc/motd.d;
# ssh.authorized_keys.root, a key made here (its private half logs in); and network.network.$IMDS_NET_CRED,
# a static global IPv6 address, as Hetzner gives one (no router advertisement, no DHCPv6), with
# nothing of the IMDS lock. The server's log shows every GET and its status.
start_imds_server() {
  IMDS_ROOT="$WORKDIR/imds"
  IMDS_LOG="$WORKDIR/imds.log"
  M="$IMDS_ROOT/hetzner/v1/metadata"
  mkdir -p "$M"
  # Hetzner answers without a newline
  printf 'imds-test' > "$M/hostname"
  printf '4711' > "$M/instance-id"
  printf 'eu-central' > "$M/region"
  printf 'fsn1-dc14' > "$M/availability-zone"
  printf '198.51.100.7' > "$M/public-ipv4"
  ssh-keygen -q -t ed25519 -N "" -C boot-test-imds -f "$WORKDIR/ssh/imds"
  ssh-keygen -q -t ed25519 -N "" -C boot-test-imds-project -f "$WORKDIR/ssh/imds-project"
  printf '["%s\\n"]' "$(cat "$WORKDIR/ssh/imds-project.pub")" > "$M/public-keys"
  # the file replaces 85-imds-early.network for the link, and with it that file's prohibit route,
  # the route in imdsd's table and the fwmark rule: the lock must hold without them
  NET='[Match]\nType=ether\nKind=!*\n\n[Network]\nDHCP=ipv4\nIPv6AcceptRA=no\nAddress='"$IMDS_IPV6"'/64\n\n[DHCPv4]\nUseHostname=no\n'
  printf '{"systemd.credentials":[%s,%s,%s,%s]}' \
    '{"name":"imds-canary","text":"canary"}' \
    '{"name":"login.motd","text":"imds motd"}' \
    '{"name":"ssh.authorized_keys.root","text":"'"$(cat "$WORKDIR/ssh/imds.pub")"'\n"}' \
    '{"name":"network.network.'"$IMDS_NET_CRED"'","text":"'"$NET"'"}' \
    > "$IMDS_ROOT/hetzner/v1/userdata"
  write_http_server imds
  probe_http_server imds /hetzner/v1/userdata || return 1
  python3 -c 'import json, sys; json.load(open(sys.argv[1])); json.load(open(sys.argv[2]))' \
    "$IMDS_ROOT/hetzner/v1/userdata" "$M/public-keys" || return 1
  : > "$IMDS_LOG"
  echo "Serving the fake IMDS endpoint to the guest as http://$IMDS_ADDR/hetzner/v1/ (QEMU network $GUEST_NET, guestfwd, no host port; log $IMDS_LOG)"
}
