# shellcheck shell=sh
# Part of scripts/boot-test, sourced by it (no processes start when sourced).
# The modes of --next: the update, the fallback, the recovery paths, the key rotation.
# shellcheck disable=SC2154 # the globals are set by scripts/boot-test and the other parts
# shellcheck disable=SC2034 # and read there

# The drop-ins --fail-health writes in /etc on the state partition, so they hold for every slot:
# the health unit hangs on the first boot that runs it and fails at once on every later one (the
# file in /var says which), and boot-complete.target's deadline is 90 s instead of the image's
HEALTH_DROPIN=/etc/systemd/system/golconda-health-network.service.d/zz-boot-test.conf
DEADLINE_DROPIN=/etc/systemd/system/boot-complete.target.d/zz-boot-test.conf
HUNG_FILE=/var/lib/boot-test-health-hung

# trial_trace MARK: the trial boot policy's lines in the serial log after byte MARK, one per line:
# the generator's verdict on each boot, the health unit's, the reboot
trial_trace() {
  tail -c +"$(($1 + 1))" "$SERIAL_LOG" | tr -d '\033\r' \
    | grep -ao "golconda-trial-boot: [^ ]* is on trial\|golconda-trial-boot: [^ ]* had no try left\|boot-test: health [a-z]*\|golconda-trial-boot: boot-complete.target failed\|golconda-trial-boot: the initrd failed" || true
}

# wait_for_old: wait, without a reboot of the harness's own, until the old release answers; a boot of
# the candidate that answers before it fails is passed over
wait_for_old() {
  PREV=$1
  while wait_for_ssh "$PREV"; do
    V=$(guest_version)
    echo "boot $BOOT_ID: $V"
    [ "$V" != "$OLD_VERSION" ] || return 0
    PREV=$BOOT_ID
  done
  return 1
}

# test_fail_health: the trial boot policy and the three-boot fallback of docs/design/boot.md. A
# drop-in in /etc breaks golconda-health-network.service: the candidate's first try hangs until the
# deadline, its second and third fail at once. The harness starts the first try; after that it
# only watches. The policy must reboot each try by itself, systemd-boot must count it, and the
# fourth boot must be the old release, blessed, where the broken unit does not run and nothing
# reboots. Then the candidate, with no try left, is started once more by hand: it fails its health
# check and must stay up.
test_fail_health() {
  echo ""
  echo "=== the fallback: $NEXT_VERSION fails its health check three times ==="
  RC=0
  guest "mkdir -p ${HEALTH_DROPIN%/*} ${DEADLINE_DROPIN%/*} && rm -f $HUNG_FILE && cat > $HEALTH_DROPIN" <<EOF || RC=1
[Service]
StandardOutput=file:/dev/kmsg
TimeoutStartSec=infinity
ExecStart=
ExecStart=/usr/bin/sh -c 'if [ -e $HUNG_FILE ]; then echo "boot-test: health fails"; exit 1; fi; touch $HUNG_FILE; echo "boot-test: health hangs"; exec sleep infinity'
EOF
  printf '[Unit]\nJobTimeoutSec=90s\n' | guest "cat > $DEADLINE_DROPIN" || RC=1
  guest systemctl daemon-reload || RC=1
  verdict "health-check-broken (golconda-health-network.service hangs once, then fails; the deadline is 90 s)" $RC

  MARK=$(wc -c < "$SERIAL_LOG")
  echo "--- the operator activates $NEXT_VERSION; from here on the harness only watches ---"
  guest systemctl reboot 2>&1 || true
  if ! wait_for_old "$BOOT_ID"; then
    verdict "fallback-to-old-slot (no login of $OLD_VERSION before the timeout)" 1
    trial_trace "$MARK"
    return 1
  fi
  echo "the trial boot policy's lines on the serial console:"
  T=$(trial_trace "$MARK")
  echo "$T"
  verdict "fallback-to-old-slot ($NEXT_VERSION failed 3 times, $V boots, the harness rebooted nothing)" 0
  RC=0
  for c in 2-1 1-2 0-3; do
    echo "$T" | grep -qxF "golconda-trial-boot: ${IMAGE_ID}_$NEXT_VERSION+$c.efi is on trial" || RC=1
  done
  verdict "trial-boot-counted (the generator saw +2-1, +1-2 and +0-3: each try counted)" $RC
  REBOOTS=$(echo "$T" | grep -cxF "golconda-trial-boot: boot-complete.target failed" || true)
  RC=0
  echo "$T" | grep -A1 -xF "boot-test: health hangs" | grep -qxF "golconda-trial-boot: boot-complete.target failed" || RC=1
  verdict "trial-hang-rebooted (a hung health unit: the deadline ended the try with a reboot)" $RC
  RC=0
  [ "$(echo "$T" | grep -cxF "boot-test: health fails")" = 2 ] || RC=1
  [ "$REBOOTS" = 3 ] || RC=1
  verdict "trial-fail-rebooted (two failed health units, each try rebooted: $REBOOTS reboots by the policy)" $RC

  check_unsealed "after the fallback to $V"
  check_clock clock-not-reset-after-fallback
  L=$(guest bootctl list --no-pager 2>&1) || true
  echo "$L" | grep -E " (title|version|tries):" || true
  RC=0; echo "$L" | grep -q "tries: 0 left; 3 done" || RC=1
  verdict "counter-exhausted (the candidate has tries: 0 left; 3 done)" $RC
  RC=0; echo "$L" | grep "$OLD_VERSION" | grep -q "(selected)" || RC=1
  verdict "old-slot-selected ($OLD_VERSION is the entry systemd-boot picked)" $RC

  # the old release is blessed: no LoaderBootCountPath, so no boot-complete.target, no health unit
  # and no trial drop-in; the broken unit cannot reboot it
  G=$(guest "ls /run/systemd/generator/boot-complete.target.d 2>/dev/null; systemctl is-active golconda-health-network.service boot-complete.target" 2>&1) || true
  echo "$G"
  RC=0
  ! echo "$G" | grep -q golconda-trial-boot || RC=1
  [ "$(echo "$G" | grep -c '^inactive$')" = 2 ] || RC=1
  verdict "blessed-no-trial-policy (the blessed entry runs no health unit and has no trial drop-in)" $RC

  echo "--- the candidate once more, with no try left (bootctl set-oneshot) ---"
  MARK=$(wc -c < "$SERIAL_LOG")
  guest bootctl set-oneshot "${IMAGE_ID}_$NEXT_VERSION.efi" || true
  reboot_guest || return 1
  V=$(guest_version)
  EXHAUSTED_BOOT=$BOOT_ID
  # the health unit fails at once (the file in /var is there); give a reboot time to happen
  sleep 20
  T=$(trial_trace "$MARK")
  echo "$T"
  H=$(guest "systemctl is-failed golconda-health-network.service; cat /proc/sys/kernel/random/boot_id" 2>&1) || true
  echo "$H"
  RC=0
  [ "$V" = "$NEXT_VERSION" ] || RC=1
  echo "$T" | grep -qxF "golconda-trial-boot: ${IMAGE_ID}_$NEXT_VERSION+0-4.efi had no try left" || RC=1
  echo "$T" | grep -qxF "boot-test: health fails" || RC=1
  ! echo "$T" | grep -qxF "golconda-trial-boot: boot-complete.target failed" || RC=1
  echo "$H" | grep -qx failed || RC=1
  echo "$H" | grep -qxF "$EXHAUSTED_BOOT" || RC=1
  verdict "exhausted-entry-stays-up ($V, no try left: its health check failed and nothing rebooted it)" $RC
  reboot_guest || return 1
  V=$(guest_version)
  RC=0; [ "$V" = "$OLD_VERSION" ] || RC=1
  verdict "oneshot-exhausted-is-once (running $V)" $RC

  guest "rm -f $HEALTH_DROPIN $DEADLINE_DROPIN $HUNG_FILE && rmdir ${HEALTH_DROPIN%/*} ${DEADLINE_DROPIN%/*} && systemctl daemon-reload" || true
}

# refusal_evidence JOURNAL: true when sysupdate's journal shows the index check failing (a bad
# signature of SHA256SUMS) and no install
refusal_evidence() {
  printf '%s\n' "$1" | grep -qiE 'BAD signature|Signature verification failed|DOWNLOAD INVALID' || return 1
  ! printf '%s\n' "$1" | grep -q 'Successfully installed'
}

# test_update_refused RC JOURNAL: --tamper-index. The update must fail on the index, install nothing
# and leave the old release running after a reboot. RC is the service's result.
test_update_refused() {
  echo ""
  echo "=== the tampered index: the update must be refused ==="
  echo "sysupdate journal (gpg lines):"
  echo "$2" | grep -i "gpg\|signature\|verif" | tail -10 || true
  R=0
  [ "$1" != 0 ] || R=1
  refusal_evidence "$2" || R=1
  PARTS=$(guest ls /dev/disk/by-partlabel 2>&1) || true
  ENTRIES=$(guest "ls /boot/EFI/Linux; bootctl list --no-pager" 2>&1) || true
  echo "partitions: $(echo "$PARTS" | tr '\n' ' ')"
  echo "$ENTRIES" | grep -E "\.efi|id:" || true
  [ -n "$PARTS" ] || R=1
  ! echo "$PARTS" | grep -q "usr_$NEXT_VERSION" || R=1
  ! echo "$ENTRIES" | grep -q "_$NEXT_VERSION" || R=1
  verdict "sysupdate-refused (the service failed on the index signature; nothing installed or staged for $NEXT_VERSION)" $R
  echo "Rebooting; the old release must still run..."
  reboot_guest || return 1
  V=$(guest_version)
  R=0; [ "$V" = "$OLD_VERSION" ] || R=1
  verdict "boots-old ($OLD_VERSION -> $V: still the old release)" $R
  check_unsealed "after the refused update"
  check_no_failed no-failed-units-after-refused-update
  check_clock clock-not-reset-after-refused-update
}

# test_verity_keyring: the running kernel checks the signed root hash of the slot sysupdate just
# filled. dm-verity trusts the kernel's built-in certificate only, never the firmware's db
# (docs/design/trust.md): the next release of a plain --next is signed with the running kernel's
# key, so the signature activates the volume; under --rotate it is signed with the new db key,
# which db holds in this boot beside the old one but the running kernel does not carry, so the
# kernel refuses it (ENOKEY) and systemd-veritysetup activates the volume unsigned. A signed
# activation shows no "retrying without"; the volume is detached again before the reboot.
test_verity_keyring() {
  echo ""
  echo "=== the kernel's verity keyring: the signature of $NEXT_VERSION's /usr ==="
  SIG_JSON=$(guest "cat /dev/disk/by-partlabel/usr-verity-sig_$NEXT_VERSION" | tr -d '\000') || true
  # shellcheck disable=SC2016 # python's own text
  FIELDS=$(printf %s "$SIG_JSON" | python3 -c '
import json, sys
d, _ = json.JSONDecoder().raw_decode(sys.stdin.read())
print(d["rootHash"], d["signature"])' 2>&1) || true
  RH=${FIELDS%% *}
  SIG=${FIELDS#* }
  case $RH in
    *[!0-9a-f]* | "") echo "usr-verity-sig_$NEXT_VERSION: no root hash ($FIELDS)"; verdict verity-sig-read 1; return 0 ;;
  esac
  VS=/usr/lib/systemd/systemd-veritysetup
  OUT=$(guest "$VS attach golconda-sigcheck /dev/disk/by-partlabel/usr_$NEXT_VERSION /dev/disk/by-partlabel/usr-verity_$NEXT_VERSION $RH root-hash-signature=base64:$SIG 2>&1; echo attach=\$?; $VS detach golconda-sigcheck 2>&1") || true
  # the image has no grep: filter the kernel's messages here
  KLOG=$(guest journalctl -k -b -o cat --no-pager 2>&1 | grep -i 'verity' | tail -5) || true
  echo "$OUT"
  echo "$KLOG"
  RC=0
  echo "$OUT" | grep -q '^attach=0$' || RC=1
  if [ "$ROTATE" = 1 ]; then
    echo "$OUT" | grep -q "with root hash signature (.*), retrying without" || RC=1
    echo "$KLOG" | grep -q "verity: Root hash verification failed (-ENOKEY)" || RC=1
    verdict "verity-sig-db-only-refused (a root hash signed by a db certificate the kernel does not carry is refused)" $RC
  else
    ! echo "$OUT" | grep -q "retrying without" || RC=1
    verdict "verity-sig-builtin-accepted (the next release's root hash signature activates its /usr)" $RC
  fi
}

# --- --next: install the next release, boot it, check its loader, then recovery ---
test_next() {
  echo ""
  echo "=== update to the next release ==="
  NEXT_NAME=$(basename "$(ls "$NEXT_RELEASE"/*.efi)" .efi)
  NEXT_VERSION=${NEXT_NAME##*_}
  IMAGE_ID=${NEXT_NAME%_*}
  test_release_index
  OLD_VERSION=$(guest_version)
  OLD_LOADER=$(guest_hash "$ESP_REMOVABLE")
  echo "running $OLD_VERSION, installing $NEXT_VERSION from http://$UPDATE_ADDR:$HTTP_PORT/"
  push_admin_vars

  echo ""
  echo "=== the guest's own sysupdate definition ==="
  DEF=$(guest cat /usr/lib/sysupdate.d/10-usr.transfer 2>&1) || true
  echo "$DEF"
  RC=0
  echo "$DEF" | grep -q '^Type=url-file$' || RC=1
  echo "$DEF" | grep -q "^Path=http://$UPDATE_ADDR:$HTTP_PORT/$" || RC=1
  verdict "http-source (10-usr.transfer: Type=url-file, Path=http://$UPDATE_ADDR:$HTTP_PORT/)" $RC

  echo ""
  echo "=== systemd-sysupdate-update.service ==="
  RC=0
  guest systemctl start --wait systemd-sysupdate-update.service || RC=1
  JOURNAL=$(guest journalctl -b -u systemd-sysupdate-update.service -o cat --no-pager 2>&1) || true
  echo "$JOURNAL" | grep "Successfully installed" || true
  # sysupdate logs "Successfully installed '<source URL>' ... as '<target>' ...": for a url-file
  # source the source is the http URL, not a local path
  RC_FETCH=0
  echo "$JOURNAL" | grep -q "Successfully installed 'http://$UPDATE_ADDR:$HTTP_PORT/" || RC_FETCH=1
  if [ "$TAMPER_INDEX" != 1 ]; then
    verdict "http-fetch (the journal names the release over http, not a local file)" $RC_FETCH
  fi
  # Verify=yes: systemd-pull fetches the index's signature and gpg checks it before any payload
  RC_SIG=0
  grep -q '"GET /SHA256SUMS.gpg HTTP/1.[01]" 200' "$HTTP_LOG" || RC_SIG=1
  verdict "index-signed (the guest fetched SHA256SUMS.gpg)" $RC_SIG
  if [ "$TAMPER_INDEX" = 1 ]; then
    test_update_refused "$RC" "$JOURNAL"
    return
  fi
  verdict "sysupdate-installed ($NEXT_VERSION)" $RC
  if [ "$RC" != 0 ]; then
    echo "HTTP server log (last 20 lines):"
    tail -20 "$HTTP_LOG" 2>/dev/null || true
    echo "sysupdate journal (gpg lines):"
    echo "$JOURNAL" | grep -i "gpg\|signature\|verif" | tail -10 || true
  fi
  [ "$RC" != 0 ] || test_verity_keyring

  if [ "$FAIL_HEALTH" = 1 ]; then
    # no blessed boot of the candidate, so no loader and no recovery checks here
    test_fail_health || return 1
    check_units_composed -after-fallback
    check_no_failed no-failed-units-after-update
    return 0
  fi
  echo "Rebooting into $NEXT_VERSION..."
  reboot_guest || return 1
  V=$(guest_version)
  RC=0; [ "$V" = "$NEXT_VERSION" ] || RC=1
  verdict "boots-next ($OLD_VERSION -> $V)" $RC
  check_unsealed "after the update to $V"
  check_units_composed -after-update
  check_no_failed no-failed-units-after-update
  check_clock clock-not-reset-after-update
  check_hwdb hwdb-after-update
  test_certs cert-login-after-update
  test_loader "$NEXT_VERSION, its first good boot" 1
  NEW_LOADER=$(guest_hash "$ESP_REMOVABLE")
  if [ "$NEW_LOADER" != "$OLD_LOADER" ]; then
    FB=$(guest_hash "$ESP_FALLBACK")
    echo "$ESP_FALLBACK: $FB"
    RC=0; [ "$FB" = "$OLD_LOADER" ] || RC=1
    verdict "loader-replaced (the previous loader kept as $ESP_FALLBACK)" $RC
  else
    echo "INFO: $NEXT_VERSION carries the loader bytes of $OLD_VERSION; nothing replaced"
  fi
  if [ "$ROTATE" = 1 ]; then
    RC=0; [ "$NEW_LOADER" != "$OLD_LOADER" ] || RC=1
    verdict "loader-signed-again (a new db key gives new loader bytes)" $RC
  fi

  test_recovery
}

# --- the recovery paths of docs/design/bootloader.md, on a machine with two slots ---
test_recovery() {
  OLD_ENTRY=${IMAGE_ID}_${OLD_VERSION}.efi
  NEXT_ENTRY=${IMAGE_ID}_${NEXT_VERSION}.efi

  echo ""
  echo "=== recovery: bootctl list ==="
  L=$(guest bootctl list --no-pager 2>&1) || true
  echo "$L" | grep -E " (title|id|source|tries):" || true
  RC=0
  { echo "$L" | grep -q "id: $OLD_ENTRY" && echo "$L" | grep -q "id: $NEXT_ENTRY"; } || RC=1
  verdict "bootctl-list-both-slots" $RC

  echo ""
  echo "=== recovery: reinstall a damaged loader ==="
  guest "echo damaged > $ESP_REMOVABLE && sync"
  echo "$ESP_REMOVABLE damaged: $(guest_hash "$ESP_REMOVABLE")"
  RC=0
  guest /usr/lib/golconda/golconda-loader-update || RC=1
  [ "$(guest_hash "$ESP_REMOVABLE")" = "$(guest_hash "$USR_LOADER")" ] || RC=1
  verdict "loader-reinstall (golconda-loader-update by hand; the boots below start from it)" $RC

  echo ""
  echo "=== recovery: bootctl set-oneshot (the other slot, once) ==="
  guest bootctl set-oneshot "$OLD_ENTRY"
  reboot_guest || return 1
  V=$(guest_version)
  RC=0; [ "$V" = "$OLD_VERSION" ] || RC=1
  verdict "set-oneshot-other-slot (running $V)" $RC
  # a blessed entry has no counter: bless-boot does not run, so golconda-loader-update does not
  # either, and the ESP keeps the newer release's loader
  LU=$(guest systemctl is-active golconda-loader-update.service 2>/dev/null) || true
  RC=0
  { [ "$LU" != active ] && [ "$(guest_hash "$ESP_REMOVABLE")" = "$NEW_LOADER" ]; } || RC=1
  verdict "other-slot-keeps-loader (golconda-loader-update.service: $LU)" $RC
  reboot_guest || return 1
  V=$(guest_version)
  RC=0; [ "$V" = "$NEXT_VERSION" ] || RC=1
  verdict "oneshot-is-once (running $V)" $RC

  echo ""
  echo "=== recovery: bootctl set-default (the other slot, until cleared) ==="
  guest bootctl set-default "$OLD_ENTRY"
  reboot_guest || return 1
  V=$(guest_version)
  RC=0; [ "$V" = "$OLD_VERSION" ] || RC=1
  verdict "set-default-other-slot (running $V)" $RC
  # ssh joins its arguments into one command line: the empty argument must be quoted there
  guest "bootctl set-default ''"
  reboot_guest || return 1
  V=$(guest_version)
  RC=0; [ "$V" = "$NEXT_VERSION" ] || RC=1
  verdict "set-default-cleared (running $V)" $RC

  echo ""
  echo "=== recovery: the firmware menu ==="
  FW_MARK=$(wc -c < "$SERIAL_LOG")
  guest bootctl reboot-to-firmware true 2>&1 || true
  guest bootctl reboot-to-firmware 2>&1 || true
  guest systemctl reboot 2>&1 || true
  FW=1
  FW_WAIT=0
  while [ "$FW_WAIT" -lt 45 ] && qemu_running; do
    if tail -c +"$((FW_MARK + 1))" "$SERIAL_LOG" | grep -aq "Boot Maintenance Manager"; then
      FW=0
      break
    fi
    FW_WAIT=$((FW_WAIT + 1))
    sleep 1
  done
  # OVMF (edk2-stable202408) draws its front page with cursor moves; the item texts are plain runs
  tail -c +"$((FW_MARK + 1))" "$SERIAL_LOG" \
    | grep -ao "Please select boot device:\|Device Manager\|Boot Maintenance Manager\|UEFI [A-Za-z0-9 ]*Device" | sort -u || true
  verdict "reboot-to-firmware (OVMF's boot menu on the serial console)" $FW
}

# db_certs LOG: the db certificates the kernel loaded, "<CN>: <key id>", one per line
db_certs() {
  tr -d '\033' < "$1" | grep -a "integrity: Loaded X.509 cert" \
    | sed "s/.*Loaded X.509 cert '\(.*\)'.*/\1/" | tr ' ' '_' | sort -u
}

# rotate_tpm: swtpm ends when QEMU disconnects; a QEMU run after the first needs one again, on the
# same state (a power cycle)
rotate_tpm() {
  [ "$TPM" = 1 ] || return 0
  [ -S "$TPM_DIR/swtpm-sock" ] || start_tpm
}

# --- --rotate: db holds the new key only, dbx the old; boot the new chain, refuse the old ---
test_rotate() {
  echo ""
  echo "=== key rotation: db = the new certificate, dbx += the old one ==="
  stop_qemu
  virt-fw-vars --input "$VARS" --output "$VARS.new" \
    --delete db --add-db "$GUID" "$NEXT_KEYS/secureboot/db.crt" \
    --add-dbx-cert "$GUID" "$KEYS_DIR/secureboot/db.crt" 2>&1 | grep -v "^INFO: \\(reading\\|var store\\|writing\\)" || true
  mv "$VARS.new" "$VARS"

  SERIAL_LOG=$WORKDIR/serial-rotated.log
  SAVED_TIMEOUT=$TIMEOUT
  TIMEOUT=240
  rotate_tpm
  start_qemu
  TIMEOUT=$SAVED_TIMEOUT
  if ! wait_for_ssh ""; then
    verdict "boots-after-rotation (no login before the timeout)" 1
    return 1
  fi
  V=$(guest_version)
  RC=0; [ "$V" = "$NEXT_VERSION" ] || RC=1
  verdict "boots-after-rotation (running $V)" $RC
  SB=$(guest bootctl status 2>&1 | grep "Secure Boot:") || true
  echo "$SB"
  RC=0; echo "$SB" | grep -q "enabled" || RC=1
  verdict "secure-boot-enabled-after-rotation" $RC
  # the kernel loads db into its .platform keyring and logs each certificate ("integrity:"); the
  # verity signature is checked against the kernel's built-in key, not that keyring
  BEFORE=$(db_certs "$FIRST_SERIAL_LOG")
  AFTER=$(db_certs "$SERIAL_LOG")
  echo "db certificates the kernel loaded before the rotation:"
  echo "$BEFORE"
  echo "after:"
  echo "$AFTER"
  RC=0
  [ -n "$AFTER" ] || RC=1
  [ "$(echo "$AFTER" | wc -l)" -lt "$(echo "$BEFORE" | wc -l)" ] || RC=1
  for c in $AFTER; do echo "$BEFORE" | grep -qxF "$c" || RC=1; done
  verdict "kernel-db-rotated (the kernel keeps the new certificate only)" $RC
  test_loader "after the rotation" 0
  check_no_failed no-failed-units-after-rotation
  check_clock clock-not-reset-after-rotate
  stop_qemu

  echo ""
  echo "=== negative control: the original disk under the rotated keys ==="
  OVERLAY=$WORKDIR/disk-original.qcow2
  SERIAL_LOG=$WORKDIR/serial-original.log
  TIMEOUT=45
  rotate_tpm
  start_qemu
  TIMEOUT=$SAVED_TIMEOUT
  wait "$QEMU_PID" 2>/dev/null || true
  tr -d '\033' < "$SERIAL_LOG" | grep -a "Access Denied\|Linux version" | sort -u || true
  RC=0
  tr -d '\033' < "$SERIAL_LOG" | grep -aq "Access Denied" || RC=1
  ! grep -aq "Linux version" "$SERIAL_LOG" || RC=1
  verdict "old-loader-refused (dbx holds the old db certificate; no kernel started)" $RC
}
