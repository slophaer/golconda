#!/bin/sh
# Run the real CLI with fake host tools. No QEMU or Nix build starts.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/keys/secureboot" "$WORK/runs"
# qemu-system's OVMF: the plain and the secure code image, and the empty variable store
mkdir -p "$WORK/firmware/share/qemu"
for f in edk2-x86_64-code.fd edk2-x86_64-secure-code.fd edk2-i386-vars.fd; do
  : > "$WORK/firmware/share/qemu/$f"
done
: > "$WORK/keys/secureboot/db.crt"
: > "$WORK/disk.raw"

# every Nix call answers with the fake firmware's directory (scripts/tools.sh builds the tools and
# OVMF with nix-build); nix-build also records what it was asked for
for tool in nix-instantiate qemu-img; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$FAKE_FIRMWARE"\n' > "$WORK/bin/$tool"
done
printf '#!/bin/sh\necho "$*" >> "$FAKE_NIX_BUILD_ARGS"\nprintf "%%s\\n" "$FAKE_FIRMWARE"\n' > "$WORK/bin/nix-build"
# the tools come from Golconda's packages, never from a nix-shell over nixpkgs
printf '#!/bin/sh\necho "nix-shell $*" >> "$FAKE_NIX_BUILD_ARGS"\nexit 1\n' > "$WORK/bin/nix-shell"
# virt-fw-vars writes its --output (enroll_keys)
cat > "$WORK/bin/virt-fw-vars" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
  case $1 in --output) : > "$2"; shift ;; esac
  shift
done
EOF
cat > "$WORK/bin/qemu-system-x86_64" <<'EOF'
#!/bin/sh
set -eu
[ -z "${FAKE_QEMU_ARGS:-}" ] || echo "$*" > "$FAKE_QEMU_ARGS"
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
FAKE_NIX_BUILD_ARGS=$WORK/nix-build.args
BOOT_TEST_CACHE=$WORK/runs
export PATH FAKE_FIRMWARE FAKE_FIXTURES FAKE_NIX_BUILD_ARGS BOOT_TEST_CACHE
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
  # the work directory is under BOOT_TEST_CACHE, not /tmp
  case $run_dir in
  "$WORK/runs/"*) echo "PASS: CLI $mode work directory under BOOT_TEST_CACHE" ;;
  *)
    echo "FAIL: CLI $mode work directory $run_dir is not under $WORK/runs"
    ERRORS=$((ERRORS + 1))
    ;;
  esac
done
# without BOOT_TEST_CACHE the directory is ${XDG_CACHE_HOME:-$HOME/.cache}/golconda-boot-test
FAKE_MODE=empty FAKE_STOPPED=$WORK/stopped-xdg FAKE_RELEASE=$WORK/release-xdg \
  FAKE_TIMEOUT_PID=$WORK/timeout-pid-xdg
export FAKE_MODE FAKE_STOPPED FAKE_RELEASE FAKE_TIMEOUT_PID
env -u BOOT_TEST_CACHE XDG_CACHE_HOME="$WORK/xdg" \
  sh "$ROOT/scripts/boot-test" "$WORK/disk.raw" --keys "$WORK/keys" --timeout 3 \
  > "$WORK/xdg.out" 2>&1 || true
run_dir=$(awk '/^Work directory:/ { print $3 }' "$WORK/xdg.out")
case $run_dir in
"$WORK/xdg/golconda-boot-test/"*) echo "PASS: CLI default work directory is under XDG_CACHE_HOME" ;;
*)
  echo "FAIL: CLI default work directory $run_dir is not under $WORK/xdg/golconda-boot-test"
  ERRORS=$((ERRORS + 1))
  ;;
esac
# every mode runs on QEMU's user network 169.254.169.0/24 (the --imds endpoint, 169.254.169.254, is
# on the guest's link; the images' update source is its gateway, 169.254.169.2), not on 10.0.2.0/24
FAKE_MODE=success-systemd FAKE_STOPPED=$WORK/stopped-net FAKE_RELEASE=$WORK/release-net \
  FAKE_TIMEOUT_PID=$WORK/timeout-pid-net FAKE_QEMU_ARGS=$WORK/qemu-args
export FAKE_MODE FAKE_STOPPED FAKE_RELEASE FAKE_TIMEOUT_PID FAKE_QEMU_ARGS
sh "$ROOT/scripts/boot-test" "$WORK/disk.raw" --keys "$WORK/keys" --timeout 3 \
  > "$WORK/net.out" 2>&1 || true
if grep -q -- '-netdev user,[^ ]*net=169\.254\.169\.0/24' "$WORK/qemu-args" && ! grep -q '10\.0\.2\.' "$WORK/qemu-args"; then
  echo "PASS: CLI the default boot's user network is 169.254.169.0/24"
else
  echo "FAIL: CLI the default boot's user network: $(cat "$WORK/qemu-args" 2>&1)"
  ERRORS=$((ERRORS + 1))
fi
# the VM's tools and its firmware are Golconda's packages (scripts/tools.sh), and the boot without
# Secure Boot or TPM loads the plain OVMF without SMM
for attr in qemu-system swtpm virt-firmware openssh cpython; do
  if grep -q -- "-A packages\.[^ ]*\.$attr\( \|$\)" "$FAKE_NIX_BUILD_ARGS"; then
    echo "PASS: CLI builds packages.<system>.$attr"
  else
    echo "FAIL: CLI does not build packages.<system>.$attr: $(cat "$FAKE_NIX_BUILD_ARGS")"
    ERRORS=$((ERRORS + 1))
  fi
done
if grep -q 'nixpkgs\|nix-shell' "$FAKE_NIX_BUILD_ARGS"; then
  echo "FAIL: CLI uses nixpkgs or nix-shell: $(cat "$FAKE_NIX_BUILD_ARGS")"
  ERRORS=$((ERRORS + 1))
else
  echo "PASS: CLI uses neither nixpkgs nor nix-shell"
fi
if grep -q "file=$FAKE_FIRMWARE/share/qemu/edk2-x86_64-code\.fd" "$WORK/qemu-args" && ! grep -q 'smm=on' "$WORK/qemu-args"; then
  echo "PASS: CLI the default boot loads the plain OVMF, without SMM"
else
  echo "FAIL: CLI the default boot's firmware: $(cat "$WORK/qemu-args" 2>&1)"
  ERRORS=$((ERRORS + 1))
fi
# --secure-boot loads the Secure Boot OVMF, with SMM and secure pflash
FAKE_STOPPED=$WORK/stopped-sb FAKE_RELEASE=$WORK/release-sb FAKE_TIMEOUT_PID=$WORK/timeout-pid-sb
export FAKE_STOPPED FAKE_RELEASE FAKE_TIMEOUT_PID
sh "$ROOT/scripts/boot-test" "$WORK/disk.raw" --keys "$WORK/keys" --secure-boot --timeout 3 \
  > "$WORK/sb.out" 2>&1 || true
if grep -q "file=$FAKE_FIRMWARE/share/qemu/edk2-x86_64-secure-code\.fd" "$WORK/qemu-args" &&
   grep -q 'smm=on' "$WORK/qemu-args" && grep -q 'cfi.pflash01,property=secure,value=on' "$WORK/qemu-args"; then
  echo "PASS: CLI --secure-boot loads the Secure Boot OVMF, with SMM"
else
  echo "FAIL: CLI --secure-boot's firmware: $(cat "$WORK/qemu-args" 2>&1) $(cat "$WORK/sb.out")"
  ERRORS=$((ERRORS + 1))
fi
unset FAKE_QEMU_ARGS
# --imds and --next together are accepted: the run goes on to --next's own checks of DIR
actual=0
sh "$ROOT/scripts/boot-test" "$WORK/disk.raw" --keys "$WORK/keys" --imds --next "$WORK/no-next" \
  > "$WORK/imds-next.out" 2>&1 || actual=$?
if [ "$actual" = 1 ] && grep -q 'no-next has no disk/release/SHA256SUMS' "$WORK/imds-next.out" &&
   ! grep -q -- '--imds.*excludes\|--imds needs' "$WORK/imds-next.out"; then
  echo "PASS: CLI --imds with --next is not refused"
else
  echo "FAIL: CLI --imds with --next (exit $actual): $(cat "$WORK/imds-next.out")"
  ERRORS=$((ERRORS + 1))
fi
[ "$ERRORS" -eq 0 ]
