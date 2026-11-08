# shellcheck shell=sh
# Part of scripts/boot-test, sourced by it (no processes start when sourced).
# The update server: the release directory over HTTP for --next, as a QEMU guest forward.
# shellcheck disable=SC2154 # the globals are set by scripts/boot-test and the other parts
# shellcheck disable=SC2034,SC2153 # and read there

# --- the release HTTP server (--next) ---
# The image's url-file source is http://10.0.2.2:$HTTP_PORT/ (8074 in the test image). The harness
# opens no host port for it: QEMU's user network forwards the guest's connections to that address
# to a command (start_qemu: guestfwd=tcp:10.0.2.2:$HTTP_PORT-cmd:$WORKDIR/serve), which QEMU
# starts once per connection with the connection on its stdin and stdout. Two runs on one host
# both serve "8074" to their own guest and share nothing. The command is the standard library's
# SimpleHTTPRequestHandler over stdio, so the guest sees the same server `python3 -m http.server`
# was (HTTP/1.0, one request per connection, no ranges).

# write_http_server: $WORKDIR/serve, next to the release copy ($WORKDIR/http) and its log
write_http_server() {
  cat > "$WORKDIR/serve" <<'EOF'
#!/usr/bin/env python3
# Serve one HTTP connection on stdin/stdout from ./http beside this file (QEMU guestfwd cmd:).
import functools, http.server, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = open(os.path.join(HERE, "http.log"), "a", buffering=1)


class Handler(http.server.SimpleHTTPRequestHandler):
    def setup(self):
        self.rfile = sys.stdin.buffer
        self.wfile = sys.stdout.buffer

    def finish(self):
        self.wfile.flush()

    def log_message(self, fmt, *args):
        LOG.write("%s [%d] %s\n" % (self.log_date_time_string(), os.getpid(), fmt % args))


Handler(None, ("guest", 0), None, directory=os.path.join(HERE, "http"))
EOF
  chmod +x "$WORKDIR/serve"
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
  if [ "${BOOT_TEST_TAMPER_INDEX:-0}" = 1 ]; then
    chmod u+w "$HTTP_ROOT/SHA256SUMS"
    printf '\n' >> "$HTTP_ROOT/SHA256SUMS"
    echo "BOOT_TEST_TAMPER_INDEX=1: served SHA256SUMS has one byte more than its signature covers"
  fi

  write_http_server
  # the same request the guest sends first; a 200 and the file's own bytes
  ANSWER=$(printf 'GET /SHA256SUMS HTTP/1.0\r\n\r\n' | "$WORKDIR/serve" 2>"$WORKDIR/serve.err" | head -n 1) || true
  case $ANSWER in
    "HTTP/1."*" 200 "*) ;;
    *)
      echo "Error: the release server answered '$ANSWER' to GET /SHA256SUMS; its stderr:" >&2
      cat "$WORKDIR/serve.err" >&2 || true
      return 1
      ;;
  esac
  : > "$HTTP_LOG"

  echo "Serving $NEXT_RELEASE to the guest as http://10.0.2.2:$HTTP_PORT/ (QEMU guestfwd, no host port; log $HTTP_LOG)"
}
