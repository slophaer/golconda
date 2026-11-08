# shellcheck shell=sh
# Part of scripts/boot-test, sourced by it (no processes start when sourced).
# The guest: ssh, waiting for a login, a verdict, small queries, reboot.
# shellcheck disable=SC2154 # the globals are set by scripts/boot-test and the other parts
# shellcheck disable=SC2034 # and read there

# --- SSH tests ---
# ssh takes the first value of an option: the host key options are separate
NO_HOSTKEY_CHECK="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SSH_OPTS="-F /dev/null \
  -o ConnectTimeout=2 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 \
  -o BatchMode=yes -o LogLevel=ERROR -p $SSH_PORT"

guest() {
  # shellcheck disable=SC2086
  ssh $SSH_OPTS $NO_HOSTKEY_CHECK -i "$WORKDIR/ssh/user" root@localhost "$@"
}

# wait for an ssh login while QEMU runs; $1: the boot id it must differ from
wait_for_ssh() {
  SSH_LAST=""
  while qemu_running; do
    if BOOT_ID=$(guest cat /proc/sys/kernel/random/boot_id 2>/dev/null) \
      && [ -n "$BOOT_ID" ] && [ "$BOOT_ID" != "${1:-}" ]; then
      return 0
    fi
    # shellcheck disable=SC2086
    SSH_LAST=$(ssh $SSH_OPTS $NO_HOSTKEY_CHECK -v -i "$WORKDIR/ssh/user" root@localhost true 2>&1) || true
    sleep 2
  done
  return 1
}

# one check: $1 name, $2 0 for PASS; counts into PASS/FAIL
verdict() {
  if [ "$2" = 0 ]; then
    echo "PASS: $1"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $1"
    FAIL=$((FAIL + 1))
  fi
}

# cert_login NAME: log in as root with the user certificate cert-NAME (and only it)
cert_login() {
  # shellcheck disable=SC2086
  ssh $SSH_OPTS $NO_HOSTKEY_CHECK -o IdentitiesOnly=yes -i "$WORKDIR/ssh/cert-$1" root@localhost true
}

# expect_login LABEL NAME 0|1: cert-NAME logs in (0) or is refused (1)
expect_login() {
  RC=0
  if cert_login "$2" 2>/dev/null; then got=0; else got=1; fi
  [ "$got" = "$3" ] || RC=1
  verdict "$1" $RC
}

# --- the boot loader on the ESP (docs/design/bootloader.md) ---
# The harness runs qemu-system-x86_64, so the names are x64's.
USR_LOADER=/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed
ESP_PRIMARY=/boot/EFI/systemd/systemd-bootx64.efi
ESP_REMOVABLE=/boot/EFI/BOOT/BOOTX64.EFI
ESP_FALLBACK=/boot/EFI/systemd/systemd-boot-fallbackx64.efi

# guest_hash FILE: the sha256 of a file in the guest, empty when it is missing
guest_hash() {
  guest "sha256sum < $1" 2>/dev/null | cut -c1-64
}

# shellcheck disable=SC2016 # $IMAGE_VERSION is the guest's
guest_version() {
  guest '. /usr/lib/os-release && echo "$IMAGE_VERSION"' 2>/dev/null
}

# reboot_guest: reboot in the same QEMU and wait for a login with a new boot id
reboot_guest() {
  PREV_BOOT_ID=$BOOT_ID
  guest systemctl reboot 2>&1 || true
  if ! wait_for_ssh "$PREV_BOOT_ID"; then
    verdict "ssh-after-reboot (no login before the timeout)" 1
    return 1
  fi
}
