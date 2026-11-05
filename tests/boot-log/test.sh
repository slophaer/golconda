#!/bin/sh
# Stored serial logs exercise the harness decisions without QEMU or the CLI.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
. "$ROOT/scripts/boot-test-log.sh"
FIXTURES=$ROOT/tests/boot-log
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ERRORS=0

expect_status() {
  expected=$1
  label=$2
  shift 2
  actual=0
  "$@" > "$WORK/output" 2>&1 || actual=$?
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $label"
  else
    echo "FAIL: $label (expected $expected, got $actual)"
    cat "$WORK/output"
    ERRORS=$((ERRORS + 1))
  fi
}

# The systemd fixture keeps the coloured success lines observed in P12.
for fixture in success-human success-units success-systemd; do
  SERIAL_LOG=$FIXTURES/$fixture.log
  expect_status 0 "$fixture markers" check_markers
done
for fixture in dependency-failed multi-user-only mentions mentions-systemd prompt empty; do
  SERIAL_LOG=$FIXTURES/$fixture.log
  expect_status 1 "$fixture markers" check_markers
done
SERIAL_LOG=$WORK/missing.log
expect_status 1 "missing log" check_markers

# Console SGR colours must not change target recognition.
printf '\033[0;32m' > "$WORK/coloured.log"
while IFS= read -r line; do
  printf '%s\n' "$line" | sed "s/target /target $(printf '\033')[0;1;39m/"
done < "$FIXTURES/success-units.log" >> "$WORK/coloured.log"
SERIAL_LOG=$WORK/coloured.log
expect_status 0 "coloured target names" check_markers

# Each required marker must affect the result.
for marker in 'Generate var' 'Started OpenSSH' 'Multi-User' 'Boot Complete'; do
  grep -v "$marker" "$FIXTURES/success-human.log" > "$WORK/incomplete.log"
  SERIAL_LOG=$WORK/incomplete.log
  expect_status 1 "missing $marker" check_markers
done

# The caller owns the guest and timeout. Use deterministic polls instead of a VM.
qemu_running() { [ "$POLLS" -lt 2 ]; }
sleep() {
  POLLS=$((POLLS + 1))
  if [ "$DELAYED_SUCCESS" = 1 ]; then
    cat "$FIXTURES/success-human.log" > "$SERIAL_LOG"
  fi
}
SERIAL_LOG=$FIXTURES/success-systemd.log
POLLS=0
DELAYED_SUCCESS=0
expect_status 0 "real systemd boot completion wait" wait_for_boot

SERIAL_LOG=$WORK/wait.log
cat "$FIXTURES/multi-user-only.log" > "$SERIAL_LOG"
POLLS=0
DELAYED_SUCCESS=1
expect_status 0 "delayed boot-complete" wait_for_boot
if [ "$POLLS" -eq 0 ]; then
  echo "FAIL: stopped at multi-user before boot-complete"
  ERRORS=$((ERRORS + 1))
fi

for fixture in multi-user-only dependency-failed mentions-systemd empty; do
  cat "$FIXTURES/$fixture.log" > "$SERIAL_LOG"
  POLLS=0
  DELAYED_SUCCESS=0
  expect_status 1 "$fixture at timeout or guest exit" wait_for_boot
done
POLLS=2
expect_status 1 "guest already exited without markers" wait_for_boot

[ "$ERRORS" -eq 0 ]
