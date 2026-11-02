#!/bin/sh
# Run the real CLI with fake host tools. No QEMU or Nix build starts.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/firmware/FV" "$WORK/keys" "$WORK/runs"
: > "$WORK/firmware/FV/OVMF_VARS.fd"
: > "$WORK/disk.raw"

for tool in nix-instantiate nix-build qemu-img; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$FAKE_FIRMWARE"\n' > "$WORK/bin/$tool"
done
cat > "$WORK/bin/qemu-system-x86_64" <<'EOF'
#!/bin/sh
set -eu
for arg do
  case "$arg" in file:*) log=${arg#file:} ;; esac
done
trap 'echo stopped > "$FAKE_STOPPED"; exit 0' TERM
if [ "$FAKE_MODE" = exited-after-poll ]; then
  echo "$PPID" > "$FAKE_TIMEOUT_PID"
  # The fake sleep releases this guest only after a failed readiness poll.
  while [ ! -f "$FAKE_RELEASE" ]; do "$FAKE_REAL_SLEEP" 0.01; done
  cp "$FAKE_FIXTURES/success-human.log" "$log"
  echo stopped > "$FAKE_STOPPED"
  exit 0
fi
if [ "$FAKE_MODE" = delayed ]; then
  cp "$FAKE_FIXTURES/multi-user-only.log" "$log"
  sleep 1
  cp "$FAKE_FIXTURES/success-human.log" "$log"
else
  cp "$FAKE_FIXTURES/$FAKE_MODE.log" "$log"
fi
if [ "$FAKE_MODE" = empty ]; then
  echo stopped > "$FAKE_STOPPED"
  exit 0
fi
while :; do sleep 0.1; done
EOF
cat > "$WORK/bin/sleep" <<'EOF'
#!/bin/sh
set -eu
if [ "$FAKE_MODE" != exited-after-poll ]; then
  exec "$FAKE_REAL_SLEEP" "$@"
fi
: > "$FAKE_RELEASE"
# Do not return to the next poll until the timeout wrapper has exited too.
for attempt in $(seq 1 200); do
  if [ -f "$FAKE_STOPPED" ] && [ -f "$FAKE_TIMEOUT_PID" ] &&
     ! kill -0 "$(cat "$FAKE_TIMEOUT_PID")" 2>/dev/null; then
    echo settled > "$FAKE_RELEASE"
    exit 0
  fi
  "$FAKE_REAL_SLEEP" 0.01
done
echo "FAIL: fake guest did not exit between polls" >&2
exit 1
EOF
chmod +x "$WORK/bin/"*
FAKE_REAL_SLEEP=$(command -v sleep)
export FAKE_REAL_SLEEP
PATH=$WORK/bin:$PATH
FAKE_FIRMWARE=$WORK/firmware
FAKE_FIXTURES=$ROOT/tests/boot-log
BOOT_TEST_TMPDIR=$WORK/runs
export PATH FAKE_FIRMWARE FAKE_FIXTURES BOOT_TEST_TMPDIR
ERRORS=0
for mode in delayed success-systemd mentions-systemd dependency-failed multi-user-only empty exited-after-poll; do
  FAKE_MODE=$mode
  FAKE_STOPPED=$WORK/stopped-$mode
  FAKE_RELEASE=$WORK/release-$mode
  FAKE_TIMEOUT_PID=$WORK/timeout-pid-$mode
  export FAKE_MODE FAKE_STOPPED FAKE_RELEASE FAKE_TIMEOUT_PID
  expected=1
  case "$mode" in delayed|success-systemd) expected=0 ;; esac
  actual=0
  sh "$ROOT/scripts/boot-test" "$WORK/disk.raw" --keys "$WORK/keys" --timeout 3 \
    > "$WORK/$mode.out" 2>&1 || actual=$?
  if [ "$actual" = "$expected" ] && [ -f "$FAKE_STOPPED" ]; then
    echo "PASS: CLI $mode (exit $actual; guest stopped)"
  else
    echo "FAIL: CLI $mode (expected $expected, got $actual; guest cleanup required)"
    cat "$WORK/$mode.out"
    ERRORS=$((ERRORS + 1))
  fi
  if [ "$mode" = exited-after-poll ]; then
    # A failed wait must survive even when final marker reporting passes.
    if [ "$(cat "$FAKE_RELEASE")" = settled ] &&
       grep -q '^PASS: 5, FAIL: 0$' "$WORK/$mode.out"; then
      echo "PASS: CLI failed wait with complete final markers"
    else
      echo "FAIL: CLI failed-wait fixture did not reach its intended state"
      cat "$WORK/$mode.out"
      ERRORS=$((ERRORS + 1))
    fi
  fi
  # Successful runs remove their work directory; failed runs retain the log.
  run_dir=$(awk '/^Work directory:/ { print $3 }' "$WORK/$mode.out")
  if { [ "$actual" = 0 ] && [ ! -d "$run_dir" ]; } ||
     { [ "$actual" != 0 ] && [ -f "$run_dir/serial.log" ]; }; then
    echo "PASS: CLI $mode work directory policy"
  else
    echo "FAIL: CLI $mode work directory policy"
    ERRORS=$((ERRORS + 1))
  fi
done
[ "$ERRORS" -eq 0 ]
