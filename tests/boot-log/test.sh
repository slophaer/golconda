#!/bin/sh
# Stored serial logs exercise the harness decisions without QEMU or the CLI.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
. "$ROOT/scripts/boot-test-log.sh"
. "$ROOT/scripts/boot-test-update.sh"
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
for marker in 'Initial Setup' 'Generate var' 'Started OpenSSH' 'Multi-User' 'Boot Complete'; do
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

# --tamper-index: the update is refused when sysupdate's journal shows the index check failing and
# no install; an unrelated failure or an install is not a refusal
BAD_SIG='Downloading 119B for http://169.254.169.2:8074/SHA256SUMS.gpg.
Download of http://169.254.169.2:8074/SHA256SUMS.gpg complete.
gpg: BAD signature from "Golconda smoke release index <index@golconda.invalid>" [unknown]
DOWNLOAD INVALID: Signature verification failed.'
expect_status 0 "tamper: a bad index signature is a refusal" refusal_evidence "$BAD_SIG"
expect_status 1 "tamper: an install is no refusal" refusal_evidence "$BAD_SIG
Successfully installed 'http://169.254.169.2:8074/boot-test_20261031.2.usr.x.raw' as 'usr_20261031.2'"
expect_status 1 "tamper: a download error is no refusal" refusal_evidence "Failed to download http://169.254.169.2:8074/SHA256SUMS: HTTP 404"
expect_status 1 "tamper: an empty journal is no refusal" refusal_evidence ""

# check_clock after every later boot: the TPM reboot, the update (--next), the fallback
# (--fail-health) and the refused update (--tamper-index) each report their own marker, read
# from this boot's journal only (journalctl -b). A stub guest answers with FAKE_JOURNAL for
# `journalctl -b` and adds an earlier boot's 1980 entries without -b. The other checks are stubs.
. "$ROOT/scripts/boot-test-guest.sh"
. "$ROOT/scripts/boot-test-checks.sh"
. "$ROOT/scripts/boot-test-modes.sh"
REPO_DIR=$ROOT
WORKDIR=$WORK
GOOD='1794000000.000001 boot-test kernel: Linux version 6.17
1794000004.250000 boot-test systemd[1]: Reached target multi-user.target - Multi-User System.'
RESET='1794000000.000001 boot-test kernel: Linux version 6.17
1794000000.500000 boot-test systemd[1]: System time is further ahead than 15y after build time, resetting clock to build time.'
BEFORE_EPOCH='315532800.000001 boot-test kernel: Linux version 6.17
315532804.000000 boot-test systemd[1]: Reached target multi-user.target - Multi-User System.'
guest() {
  case "$*" in
    *"journalctl -b "*short-unix*) printf '%s\n' "$FAKE_JOURNAL" ;;
    *journalctl*short-unix*) printf '%s\n%s\n' "$BEFORE_EPOCH" "$FAKE_JOURNAL" ;;
  esac
  return 0
}
wait_for_ssh() { BOOT_ID=next-boot; }
reboot_guest() { BOOT_ID=next-boot; }
guest_version() { echo 20261110.1; }
guest_hash() { echo 0; }
for f in check_unsealed check_no_failed check_hwdb check_units_composed test_certs_after_update \
  test_loader test_recovery test_release_index push_admin_vars; do
  eval "$f() { :; }"
done
TPM=1 TAMPER_INDEX=0 FAIL_HEALTH=0 ROTATE=0 BOOT_ID=first-boot FIRST_BOOT_ID=first-boot
OLD_VERSION=20261110.1 NEXT_VERSION=20261110.2 UPDATE_ADDR=169.254.169.2 HTTP_PORT=8074
NEXT_RELEASE=$WORK/release HTTP_LOG=$WORK/http.log
mkdir -p "$NEXT_RELEASE"
: > "$NEXT_RELEASE/boot-test_$NEXT_VERSION.efi"
: > "$HTTP_LOG"

# expect_clock MARKER COMMAND...: COMMAND reports MARKER once, as PASS on a good journal of this
# boot, and as FAIL when this boot's journal has a clock reset or an entry from before the epoch
expect_clock() {
  marker=$1
  shift
  for journal in GOOD:PASS RESET:FAIL BEFORE_EPOCH:FAIL; do
    case $journal in
      GOOD:*) FAKE_JOURNAL=$GOOD ;;
      RESET:*) FAKE_JOURNAL=$RESET ;;
      *) FAKE_JOURNAL=$BEFORE_EPOCH ;;
    esac
    PASS=0 FAIL=0
    ("$@") > "$WORK/clock.out" 2>&1 || true
    if [ "$(grep -c "^[A-Z]*: $marker " "$WORK/clock.out")" = 1 ] &&
      grep -q "^${journal#*:}: $marker " "$WORK/clock.out"; then
      echo "PASS: $marker on a ${journal%:*} journal"
    else
      echo "FAIL: $marker on a ${journal%:*} journal (expected ${journal#*:})"
      grep "clock" "$WORK/clock.out" || true
      ERRORS=$((ERRORS + 1))
    fi
  done
}
expect_clock clock-not-reset check_clock clock-not-reset
expect_clock clock-not-reset-after-reboot test_reboot
expect_clock clock-not-reset-after-update test_next
expect_clock clock-not-reset-after-fallback test_fail_health
expect_clock clock-not-reset-after-refused-update test_update_refused 1 "$BAD_SIG"

# --rotate: test_rotate boots the rotated release once, and checks the clock of that boot. Stubs
# for QEMU and the variable store; the serial logs hold no db certificates, so its other
# verdicts fail, which expect_clock does not read.
stop_qemu() { :; }
start_qemu() { : > "$SERIAL_LOG"; }
QEMU_PID=
mkdir -p "$WORK/bin"
printf '#!/bin/sh\n: > "$VARS.new"\n' > "$WORK/bin/virt-fw-vars"
chmod +x "$WORK/bin/virt-fw-vars"
PATH=$WORK/bin:$PATH
export VARS
VARS=$WORK/vars.fd
NEXT_KEYS=$WORK/nkeys KEYS_DIR=$WORK/keys GUID=0
TIMEOUT=1
FIRST_SERIAL_LOG=$WORK/first.log
: > "$FIRST_SERIAL_LOG"
TPM_DIR=$WORK/tpm
TPM_STARTS=0
start_tpm() { TPM_STARTS=$((TPM_STARTS + 1)); }
expect_clock clock-not-reset-after-rotate test_rotate

# swtpm ends when QEMU disconnects: each QEMU run of --rotate (the rotated boot and the negative
# control) needs a TPM of its own, on the same state, when --tpm is set
TPM_STARTS=0
FAKE_JOURNAL=$GOOD
test_rotate > /dev/null 2>&1 || true
if [ "$TPM_STARTS" = 2 ]; then
  echo "PASS: rotate starts a TPM for each of its two QEMU runs"
else
  echo "FAIL: rotate started $TPM_STARTS TPMs, want 2"
  ERRORS=$((ERRORS + 1))
fi

[ "$ERRORS" -eq 0 ]
