# shellcheck shell=sh
# Part of scripts/boot-test, sourced by it (no processes start when sourced).
# The update server: the release directory over HTTP for --next.
# shellcheck disable=SC2154 # the globals are set by scripts/boot-test and the other parts
# shellcheck disable=SC2034,SC2153 # and read there

# http_port_in_use PORT: true when 127.0.0.1:PORT is already bound
http_port_in_use() {
  python3 - "$1" <<'EOF'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(0)
sys.exit(1)
EOF
}

# http_answers PORT: true when 127.0.0.1:PORT accepts a connection
http_answers() {
  python3 - "$1" <<'EOF'
import socket, sys
try:
    socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1).close()
except OSError:
    sys.exit(1)
EOF
}

# --- the release HTTP server (--next) ---
# start_http_server: serve the release directory on the host, where the image's url-file source
# expects it. QEMU user networking maps 10.0.2.2 to the host loopback.
start_http_server() {
  HTTP_ROOT="$WORKDIR/http"
  HTTP_LOG="$WORKDIR/http.log"
  mkdir -p "$HTTP_ROOT"
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

  echo "Serving $NEXT_RELEASE on http://127.0.0.1:$HTTP_PORT/ (the guest uses http://10.0.2.2:$HTTP_PORT/)"
  python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$HTTP_ROOT" \
    > "$HTTP_LOG" 2>&1 &
  HTTP_PID=$!

  WAIT=0
  while [ "$WAIT" -lt 50 ]; do
    if ! kill -0 "$HTTP_PID" 2>/dev/null; then
      echo "Error: the HTTP server on 127.0.0.1:$HTTP_PORT exited; its log:" >&2
      cat "$HTTP_LOG" >&2 || true
      return 1
    fi
    if http_answers "$HTTP_PORT"; then
      echo "HTTP server ready (pid $HTTP_PID)"
      return 0
    fi
    WAIT=$((WAIT + 1))
    sleep 0.2
  done

  echo "Error: the HTTP server on 127.0.0.1:$HTTP_PORT did not answer within 10 s; its log:" >&2
  cat "$HTTP_LOG" >&2 || true
  return 1
}
