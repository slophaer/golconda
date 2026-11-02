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
chmod +x "$WORK/bin/"*
PATH=$WORK/bin:$PATH
FAKE_FIRMWARE=$WORK/firmware
FAKE_FIXTURES=$ROOT/tests/boot-log
BOOT_TEST_TMPDIR=$WORK/runs
export PATH FAKE_FIRMWARE FAKE_FIXTURES BOOT_TEST_TMPDIR
ERRORS=0
for mode in delayed dependency-failed multi-user-only empty; do
  FAKE_MODE=$mode
  FAKE_STOPPED=$WORK/stopped-$mode
  export FAKE_MODE FAKE_STOPPED
  expected=1
  [ "$mode" != delayed ] || expected=0
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
