# shellcheck shell=sh
# Part of scripts/boot-test, sourced by it (no processes start when sourced).
# The modes of one boot: the first-boot checks, --imds, the TPM reboot, the factory reset.
# shellcheck disable=SC2154 # the globals are set by scripts/boot-test and the other parts
# shellcheck disable=SC2034 # and read there

test_ssh() {
  echo ""
  echo "=== SSH tests ==="
  echo "Waiting for SSH..."
  if ! wait_for_ssh ""; then
    echo "last attempt (ssh -v), while QEMU still ran:"
    echo "$SSH_LAST" | tail -15
    verdict "ssh-login (no login before the timeout)" 1
    return 1
  fi
  verdict "ssh-login" 0
  FIRST_BOOT_ID=$BOOT_ID
  # remember the host key the server presents, for the second boot
  # shellcheck disable=SC2086
  ssh $SSH_OPTS -o UserKnownHostsFile="$WORKDIR/known_hosts" -o StrictHostKeyChecking=accept-new \
    -i "$WORKDIR/ssh/user" root@localhost true 2>/dev/null || true

  if [ "$IMDS" = 1 ]; then
    test_imds
  else
    echo ""
    echo "=== hostname ==="
    HN=$(guest hostname 2>&1) || true
    echo "$HN"
    EXPECT_HN=boot-test
    if [ "$ESP_CREDS" = 1 ]; then
      EXPECT_HN=esp-test
    fi
    RC=0; [ "$HN" = "$EXPECT_HN" ] || RC=1
    verdict "hostname (system.hostname credential applied)" $RC
    check_imds_off
    check_imds_lock_endpoints
  fi

  if [ "$ESP_CREDS" = 1 ]; then
    echo ""
    echo "=== authorized_keys (ESP credential) ==="
    AK=$(guest cat /root/.ssh/authorized_keys 2>&1) || true
    echo "$AK"
    RC=0; echo "$AK" | grep -qF "$(cut -d' ' -f1,2 "$WORKDIR/ssh/user.pub")" || RC=1
    verdict "esp-authorized-keys (ssh.authorized_keys.root credential written to /root/.ssh)" $RC
  fi

  check_no_failed no-failed-units
  check_clock clock-not-reset

  echo ""
  echo "=== varlinkctl list-interfaces ==="
  RC=0
  IFACES=$(guest varlinkctl list-interfaces /run/systemd/io.systemd.Manager 2>&1) || RC=1
  echo "$IFACES"
  echo "$IFACES" | grep -q "^io.systemd.Manager$" || RC=1
  verdict "varlinkctl-list-interfaces" $RC

  echo ""
  echo "=== bootctl list ==="
  guest bootctl list --no-pager 2>&1 || true

  test_loader "first boot" 1

  # the test image trusts the test user CA for boot-test-admin (nix/default.nix)
  echo ""
  echo "=== certificate login ==="
  if [ "$ENROL" = 1 ]; then
    # --enrol: nothing is pushed yet. The plain bootstrap key from the SMBIOS credential logs in;
    # a good certificate is refused, and sshd says the revocation list refused it: the image's
    # fallback list names the user CA until a KRL is pushed (modules/services/sshd)
    RC=0
    # shellcheck disable=SC2086
    ssh $SSH_OPTS $NO_HOSTKEY_CHECK -o IdentitiesOnly=yes -i "$WORKDIR/ssh/bootstrap" root@localhost true || RC=1
    verdict "bootstrap-key-login (the plain key of the SMBIOS credential ssh.authorized_keys.root)" $RC
    RC=0
    if cert_login ok 2>/dev/null; then RC=1; fi
    REFUSED=$(guest journalctl -b -u sshd.service -o cat --no-pager 2>/dev/null |
      grep "revoked by file /run/credentials/sshd.service/sshd-revoked-keys.krl") || RC=1
    echo "$REFUSED" | tail -2
    verdict "cert-refused-before-enrol (no KRL pushed: the fallback list revokes the user CA)" $RC
  else
    expect_login "cert-login (a certificate from the trusted user CA, principal boot-test-admin)" ok 0
  fi
  expect_login "cert-wrong-principal-refused" wrong 1

  check_hwdb hwdb

  check_ca_store

  # IPE (docs/design/kernel.md): only files on a dm-verity volume with a verified signature run.
  # A copy of /usr's shell on the root partition must be refused with EACCES, and the kernel must
  # log a new IPE denial; the count before and after keeps an earlier denial from passing. The
  # image has no grep, so the journal is filtered here.
  echo ""
  echo "=== IPE: a copy outside /usr ==="
  RC=0
  DENY='ipe_op=EXECUTE.* path="/var/tmp/ipe-sh".* action=DENY'
  D0=$(guest journalctl -b -o cat --no-pager 2>/dev/null | grep -c "$DENY") || D0=0
  OUT=$(guest 'cp /usr/bin/sh /var/tmp/ipe-sh && /var/tmp/ipe-sh -c true 2>&1; echo "rc=$?"; rm -f /var/tmp/ipe-sh' 2>&1) || true
  D1=$(guest journalctl -b -o cat --no-pager 2>/dev/null | grep -c "$DENY") || D1=0
  echo "$OUT"
  echo "IPE denials in the journal: $D0 before, $D1 after"
  guest journalctl -b -o cat --no-pager 2>/dev/null | grep "$DENY" | tail -1 || true
  echo "$OUT" | grep -q "Permission denied" || RC=1
  echo "$OUT" | grep -q "^rc=126$" || RC=1
  [ "$D1" -gt "$D0" ] || RC=1
  verdict "ipe-denies-copy (/var/tmp/ipe-sh: EACCES, and IPE logged the denial)" $RC

  # the signed index's keyring is the key set's release key and nothing else: systemd's own vendor
  # keyring (image vendors' keys) is not in the image (packages/systemd)
  echo ""
  echo "=== /usr/lib/systemd/import-pubring.pgp ==="
  RC=0
  WANT=$(sha256sum "$(real_path "$KEYS_DIR/release/index.pgp")" 2>/dev/null | cut -c1-64) || WANT=""
  GOT=$(guest sha256sum /usr/lib/systemd/import-pubring.pgp 2>/dev/null | cut -c1-64) || GOT=""
  echo "image: ${GOT:-missing}; key set: ${WANT:-missing}"
  [ -n "$WANT" ] && [ "$GOT" = "$WANT" ] || RC=1
  verdict "index-keyring (the image's keyring is the key set's release/index.pgp)" $RC

  if [ "$SECURE_BOOT" = 1 ]; then
    echo ""
    echo "=== secure boot state ==="
    SB=$(guest bootctl status 2>&1) || true
    echo "$SB" | grep -i "secure boot" || true
    RC=0; echo "$SB" | grep -qi "Secure Boot: enabled" || RC=1
    verdict "secure-boot-enabled (firmware is enforcing)" $RC
  fi

  if [ "$TPM" = 1 ]; then
    echo ""
    echo "=== $(dirname "$HOSTKEY_CRED") (TPM sealed credentials) ==="
    guest ls -la "$(dirname "$HOSTKEY_CRED")/" 2>&1 || true
    # the sealing key type is the first 16 bytes of the credential (systemd creds-util.h,
    # CRED_AES256_GCM_BY_*); the file is base64, so decode its first 24 characters
    HDR=$(guest "head -c 24 $HOSTKEY_CRED | base64 -d | od -An -tx1 -N4" \
      2>/dev/null | tr -d ' \n') || true
    case "$HDR" in
      5a1c6a86 | 55b9ed1d) KIND="host key only"; RC=1 ;;
      058469da) KIND="null key"; RC=1 ;;
      # TPM2 without the signed PCR 11 policy: not what the var asks for (--tpm2-public-key-pcrs=11)
      0c7cc07b | d4062dfb) KIND="TPM2" ; RC=1 ;;
      93a89409 | ef4ac136 | 14142588 | 2a1f877a) KIND="host key + TPM2"; RC=1 ;;
      faf7eb93 | 5e2d5c76) KIND="TPM2 + signed PCR policy"; RC=0 ;;
      af4950a8 | adbc4ca3 | afbfeaac | 16e49294) KIND="host key + TPM2 + signed PCR policy"; RC=0 ;;
      *) KIND="unknown"; RC=1 ;;
    esac
    echo "sshd-hostkey.key sealed with: $KIND (header id ${HDR:-none}...)"
    verdict "hostkey-sealed-with-tpm2 (and the signed PCR 11 policy)" $RC
    SEALED_HASH=$(guest_hash "$HOSTKEY_CRED")
  fi
  return 0
}

# --- --imds: a faked cloud (scripts/boot-test-http.sh serves its endpoint) ---
test_imds() {
  echo ""
  echo "=== /imds: waiting for $IMDS_UNIT ==="
  echo "DMI BIOS vendor: $(guest cat /sys/class/dmi/id/bios_vendor 2>&1)"
  wait_imds_import
  check_imds_hostname
  check_imds_layout
  check_imds_ssh_keys
  check_imds_userdata_credential
  check_imds_ipv6
  check_imds_locked
  check_imds_lock_endpoints
  check_imds_dhcp_hostname
  check_imds_ordering
}

# --- second boot, TPM: the host key is unsealed, not regenerated ---
test_reboot() {
  echo ""
  echo "=== Reboot test (TPM credential unsealing) ==="
  echo "host key of the first boot: $(ssh-keygen -lf "$WORKDIR/known_hosts" 2>/dev/null)"
  echo "Rebooting..."
  guest systemctl reboot 2>&1 || true

  if ! wait_for_ssh "$FIRST_BOOT_ID"; then
    verdict "ssh-after-reboot (no login before the timeout)" 1
    return 1
  fi
  verdict "ssh-after-reboot (boot id $FIRST_BOOT_ID -> $BOOT_ID)" 0

  check_unsealed "after a reboot"
  check_no_failed no-failed-units-after-reboot
  check_clock clock-not-reset-after-reboot
  return 0
}

# --- --factory-reset: the request and the reset boot (docs/design/recovery.md) ---
# The reset is requested with `systemctl start factory-reset.target`: the target sets the
# FactoryResetRequest EFI variable, and systemd-repart deletes and recreates the FactoryReset=
# root partition on the next boot (systemd-factory-reset(8), systemd-repart(8)). The ESP and the
# /usr slots must stay, and first boot must run again.
test_factory_reset() {
  echo ""
  echo "=== factory reset ==="
  # shellcheck disable=SC2016 # $IMAGE_ID is the guest's
  IMG_ID=$(guest '. /usr/lib/os-release && echo "$IMAGE_ID"' 2>/dev/null) || true
  if [ "$IMG_ID" != "boot-test" ]; then
    verdict "factory-reset-test-image (IMAGE_ID=${IMG_ID:-empty}; --factory-reset needs the test image)" 1
    return 1
  fi
  verdict "factory-reset-test-image (IMAGE_ID=boot-test)" 0

  MARK=/etc/boot-test-factory-reset
  OLD_MACHINE_ID=$(guest cat /etc/machine-id 2>/dev/null) || true
  OLD_VERSION=$(guest_version)
  OLD_ENTRIES=$(guest bootctl list --no-pager 2>/dev/null \
    | sed -n 's/^[[:space:]]*id: //p' | sed 's/+[0-9]*-[0-9]*\.efi$/.efi/' | sort) || true
  echo "machine id before: ${OLD_MACHINE_ID:-no answer}"
  echo "running ${OLD_VERSION:-no answer}; boot entries:"
  echo "${OLD_ENTRIES:-no answer}"
  if [ -z "$OLD_MACHINE_ID" ] || [ -z "$OLD_VERSION" ] || [ -z "$OLD_ENTRIES" ]; then
    verdict "factory-reset-before (could not read /etc/machine-id, IMAGE_VERSION or bootctl list)" 1
    return 1
  fi

  RC=0
  guest "printf 'factory-reset-test\n' > $MARK" || RC=1
  MARK_BACK=$(guest cat "$MARK" 2>/dev/null) || MARK_BACK=""
  [ "$MARK_BACK" = factory-reset-test ] || RC=1
  verdict "state-marker-written ($MARK is readable before the reset)" $RC
  [ "$RC" = 0 ] || return 1

  RESET_MARK=$(wc -c < "$SERIAL_LOG")
  PREV_BOOT_ID=$BOOT_ID
  echo "Requesting the reset: systemctl start factory-reset.target"
  # the target's systemd-factory-reset-reboot.service has SuccessAction=reboot, so this command
  # can end with the connection closing; the reset boot is what the wait below looks for
  guest systemctl start factory-reset.target 2>&1 || true
  if ! wait_for_ssh "$PREV_BOOT_ID"; then
    verdict "factory-reset-boot (no login with a new boot id before the timeout)" 1
    return 1
  fi
  echo "reset boot: $PREV_BOOT_ID -> $BOOT_ID"

  RESET_LOG="$WORKDIR/serial-reset.log"
  tail -c +"$((RESET_MARK + 1))" "$SERIAL_LOG" > "$RESET_LOG"

  # state-gone: the guest itself must say the marker is absent, so an ssh failure cannot pass
  PRESENT=$(guest "if [ -e $MARK ]; then echo present; else echo absent; fi" 2>/dev/null) || PRESENT=""
  RC=0; [ "$PRESENT" = absent ] || RC=1
  verdict "state-gone ($MARK: ${PRESENT:-no answer})" $RC

  NEW_MACHINE_ID=$(guest cat /etc/machine-id 2>/dev/null) || true
  RC=0
  { [ -n "$NEW_MACHINE_ID" ] && [ "$NEW_MACHINE_ID" != "$OLD_MACHINE_ID" ]; } || RC=1
  verdict "machine-id-new ($OLD_MACHINE_ID -> ${NEW_MACHINE_ID:-no answer})" $RC

  RC=0; grep -qi "Finished.*Initial Setup" "$RESET_LOG" || RC=1
  verdict "first-boot-rerun (systemd-firstboot.service finished on the reset boot)" $RC

  RC=0; grep -qi "Reached target.*Multi.User" "$RESET_LOG" || RC=1
  verdict "multi-user-after-reset (the reset boot reached multi-user.target)" $RC

  NEW_VERSION=$(guest_version)
  NEW_ENTRIES=$(guest bootctl list --no-pager 2>/dev/null \
    | sed -n 's/^[[:space:]]*id: //p' | sed 's/+[0-9]*-[0-9]*\.efi$/.efi/' | sort) || true
  echo "after the reset: running ${NEW_VERSION:-no answer}; boot entries:"
  echo "${NEW_ENTRIES:-no answer}"
  RC=0
  { [ -n "$NEW_ENTRIES" ] && [ "$NEW_ENTRIES" = "$OLD_ENTRIES" ] && [ "$NEW_VERSION" = "$OLD_VERSION" ]; } || RC=1
  verdict "slots-kept (bootctl list entries, ignoring the boot counter, and IMAGE_VERSION unchanged)" $RC

  echo ""
  echo "=== serial log of the reset boot (last 100 lines) ==="
  tail -100 "$RESET_LOG"
}
