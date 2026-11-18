# shellcheck shell=sh
# Part of scripts/boot-test, sourced by it (no processes start when sourced).
# The modes of --next: the update, the fallback, the recovery paths, the key rotation.

# The drop-ins --fail-health writes in /etc on the state partition, so they hold for every slot:
# the health unit hangs on the first boot that runs it and fails at once on every later one (the
# file in /var says which), and boot-complete.target's deadline is 90 s instead of the image's
HEALTH_DROPIN=/etc/systemd/system/golconda-health-network.service.d/zz-boot-test.conf
DEADLINE_DROPIN=/etc/systemd/system/boot-complete.target.d/zz-boot-test.conf
HUNG_FILE=/var/lib/boot-test-health-hung

# the activation (docs/design/updates.md, "Activation"): the image's reboot timer fires at 04:10;
# this drop-in moves its window to every 10 s, as an administrator's drop-in in /etc would
REBOOT_DROPIN=/etc/systemd/system/systemd-sysupdate-reboot.timer.d/zz-boot-test.conf

# check_reboot_window: the image enables systemd-sysupdate-reboot.timer in /system.updateReboot's
# window, systemd's 04:10 for the test image
check_reboot_window() {
  W=$(guest systemctl show -p ActiveState -p TimersCalendar systemd-sysupdate-reboot.timer 2>&1) || true
  echo "$W"
  RC=0
  echo "$W" | grep -qx 'ActiveState=active' || RC=1
  echo "$W" | grep -q 'OnCalendar=\*-\*-\* 04:10:00' || RC=1
  verdict "update-reboot-window (systemd-sysupdate-reboot.timer is active, at 04:10)" $RC
}

# activate_soon: the reboot timer fires every 10 s from now on, on every slot, until the drop-in is
# removed; the harness reboots nothing itself
activate_soon() {
  printf '[Timer]\nOnCalendar=\nOnCalendar=*:*:0/10\nRandomizedDelaySec=0\nAccuracySec=1s\n' \
    | guest "mkdir -p ${REBOOT_DROPIN%/*} && cat > $REBOOT_DROPIN && systemctl daemon-reload && systemctl restart systemd-sysupdate-reboot.timer"
}

# activate_never: remove that drop-in again
activate_never() {
  guest "rm -f $REBOOT_DROPIN && rmdir ${REBOOT_DROPIN%/*} && systemctl daemon-reload && systemctl restart systemd-sysupdate-reboot.timer" || true
}

# reboot_skipped NAME: the reboot timer fired on this boot, golconda-update-pending found
# nothing to activate, and the boot goes on
reboot_skipped() {
  guest journalctl -b -u systemd-sysupdate-reboot.service -o cat --no-pager 2>/dev/null \
    | grep -q "golconda-update-pending: the default entry is the running one: nothing to activate"
}
check_reboot_skipped() {
  RC=0
  wait_for 40 reboot_skipped || RC=1
  B=$(guest cat /proc/sys/kernel/random/boot_id 2>/dev/null) || true
  [ "$B" = "$BOOT_ID" ] || RC=1
  verdict "$1 (the reboot timer fired, golconda-update-pending found nothing to activate, no reboot)" $RC
}

# trial_trace MARK: the trial boot policy's lines in the serial log after byte MARK, one per line:
# the generator's verdict on each boot, the health unit's, the reboot
trial_trace() {
  tail -c +"$(($1 + 1))" "$SERIAL_LOG" | tr -d '\033\r' \
    | grep -ao "golconda-trial-boot: [^ ]* is on trial\|golconda-trial-boot: [^ ]* had no try left\|boot-test: health [a-z]*\|golconda-trial-boot: boot-complete.target failed\|golconda-trial-boot: emergency.target reached" || true
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

# fallback_after KIND: after the fallback to $V the candidate has no try left and the host key
# unseals; KIND ends the marker names (none for --fail-health), L gets systemd-boot's entries
fallback_after() {
  L=$(guest bootctl list --no-pager 2>&1) || true
  echo "$L" | grep -E " (title|version|tries):" || true
  RC=0; echo "$L" | grep -q "tries: 0 left; 3 done" || RC=1
  verdict "counter-exhausted${1:+-$1} (the candidate has tries: 0 left; 3 done)" $RC
  check_unsealed "after the fallback to $V"
}

# test_fail_health: the trial boot policy and the three-boot fallback of docs/design/boot.md. A
# drop-in in /etc breaks golconda-health-network.service: the candidate's first try hangs until the
# deadline, its second and third fail at once. Each try must reboot by itself and be counted, and
# the fourth boot must be the old release, blessed, where nothing reboots. The candidate, with no
# try left, then started by hand, fails its health check and must stay up. The harness only watches.
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
  echo "--- the reboot timer activates $NEXT_VERSION; the harness only watches ---"
  activate_soon || true
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
  echo "$T" | head -1 | grep -qxF "golconda-trial-boot: ${IMAGE_ID}_$NEXT_VERSION+2-1.efi is on trial" || RC=1
  verdict "update-activated (the reboot timer started $NEXT_VERSION's first try)" $RC
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

  check_clock clock-not-reset-after-fallback
  fallback_after ""
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
  # $NEXT_VERSION is installed and newer, and the timer still fires every 10 s: only
  # golconda-update-pending keeps it from rebooting the machine back into the bad entry
  check_reboot_skipped update-reboot-skipped-after-fallback

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
  activate_never
}

# test_fail_initrd: the trial boot policy in the initrd. The candidate's /usr hash tree is damaged,
# so its initrd fails each try into emergency.target, where golconda-emergency-reboot.service reboots.
# The reboot timer starts the first try; the harness only watches until the old release answers
test_fail_initrd() {
  echo ""
  echo "=== the initrd fails: $NEXT_VERSION's verity hash partition is damaged ==="
  P=/dev/disk/by-partlabel/usr-verity_$NEXT_VERSION
  RC=0
  guest "dd if=/dev/zero of=$P bs=65536 count=16 conv=notrunc && sync" || RC=1
  verdict "initrd-broken ($P: its first MiB zeroed)" $RC
  MARK=$(wc -c < "$SERIAL_LOG")
  echo "--- the reboot timer activates $NEXT_VERSION; the harness only watches ---"
  activate_soon || true
  if ! wait_for_old "$BOOT_ID"; then
    verdict "fallback-to-old-slot-initrd (no login of $OLD_VERSION before the timeout)" 1
    trial_trace "$MARK"
    return 1
  fi
  T=$(trial_trace "$MARK")
  echo "the trial boot policy's lines on the serial console:"
  echo "$T"
  verdict "fallback-to-old-slot-initrd ($NEXT_VERSION failed in the initrd 3 times, $V boots)" 0
  RC=0
  [ "$(echo "$T" | grep -cxF "golconda-trial-boot: emergency.target reached")" = 3 ] || RC=1
  # the host's generator logs on every counted boot of the host: the candidate's never started
  ! echo "$T" | grep -q "golconda-trial-boot: ${IMAGE_ID}_$NEXT_VERSION+" || RC=1
  verdict "initrd-fail-rebooted (golconda-emergency-reboot.service rebooted each of the three tries)" $RC
  fallback_after initrd
  check_reboot_skipped update-reboot-skipped-after-initrd-fallback
  activate_never
}

# serial_count MARK PATTERN: the lines of the serial log after byte MARK that hold PATTERN
serial_count() {
  tail -c +"$(($1 + 1))" "$SERIAL_LOG" | tr -d '\033\r' | grep -acF "$2" || true
}

# time_reboots MARK DOWN N: watch the serial log after byte MARK until N lines DOWN have each been
# followed by a new kernel ("Linux version"); DELAYS gets the seconds from each DOWN to that kernel
time_reboots() {
  DELAYS=
  SEEN_DOWN=0
  SINCE=
  while qemu_running; do
    D=$(serial_count "$1" "$2")
    if [ -z "$SINCE" ] && [ "$D" -gt "$SEEN_DOWN" ]; then
      SEEN_DOWN=$D
      SINCE=$(date +%s)
      KERNELS=$(serial_count "$1" "Linux version")
    fi
    if [ -n "$SINCE" ] && [ "$(serial_count "$1" "Linux version")" -gt "$KERNELS" ]; then
      DELAYS="$DELAYS $(($(date +%s) - SINCE))"
      SINCE=
      [ "$SEEN_DOWN" -lt "$3" ] || return 0
    fi
    sleep 1
  done
  return 1
}

# test_fail_tries KIND: the panic or PID 1 crash (pid1) row of the trial boot policy
# (docs/design/boot.md, "Trial boot"). The candidate's boot-test-panic.service (sysrq c) or
# boot-test-crash.service (kill -SEGV 1) fails each of three tries: panic=10 or CrashAction=reboot
# must reboot after 10 s, not the hardware watchdog after 30 s, and the fourth boot must run the old
# release. The kernel's "Rebooting in 10 seconds.." can stay in its buffer when another CPU had the
# console, so the time from the failure to the next kernel tells the two apart
test_fail_tries() {
  case $1 in
    panic)
      ARM=panic
      DOWN="Kernel panic - not syncing: sysrq triggered crash"
      ;;
    *)
      ARM=crash
      DOWN="boot-test: crash PID 1 ($NEXT_VERSION)"
      ;;
  esac
  echo ""
  echo "=== the trial boot policy: each try of $NEXT_VERSION ends in a $1 failure ==="
  RC=0
  guest "mkdir -p /var/lib/boot-test && touch /var/lib/boot-test/$ARM-$NEXT_VERSION && sync" || RC=1
  verdict "fail-$1-armed (/var/lib/boot-test/$ARM-$NEXT_VERSION)" $RC
  MARK=$(wc -c < "$SERIAL_LOG")
  echo "--- the reboot timer activates $NEXT_VERSION; the harness only watches ---"
  activate_soon || true
  RC_TIME=0
  time_reboots "$MARK" "$DOWN" 3 || RC_TIME=1
  echo "seconds from each failure to the next kernel:$DELAYS"
  if ! wait_for_old "$BOOT_ID"; then
    verdict "fallback-to-old-slot-$1 (no login of $OLD_VERSION before the timeout)" 1
    trial_trace "$MARK"
    return 1
  fi
  # one line per event: the generator's verdict, the test unit, the kernel's panic
  T=$(tail -c +"$((MARK + 1))" "$SERIAL_LOG" | tr -d '\033\r' \
    | grep -ao "golconda-trial-boot: [^ ]* is on trial\|boot-test: [a-z]* [^(]*([0-9.]*)\|Kernel panic - not syncing: sysrq triggered crash" || true)
  echo "the policy's and the kernel's lines on the serial console:"
  echo "$T"
  verdict "fallback-to-old-slot-$1 ($NEXT_VERSION failed 3 times, $V boots, the harness rebooted nothing)" 0
  RC=$RC_TIME
  for c in 2-1 1-2 0-3; do
    echo "$T" | grep -qxF "golconda-trial-boot: ${IMAGE_ID}_$NEXT_VERSION+$c.efi is on trial" || RC=1
  done
  [ "$(echo "$T" | grep -cxF "$DOWN")" = 3 ] || RC=1
  # 10 s and a firmware start: more than 8 s, less than the watchdog's 30 s
  N=0
  for d in $DELAYS; do
    N=$((N + 1))
    { [ "$d" -ge 8 ] && [ "$d" -le 25 ]; } || RC=1
  done
  [ "$N" = 3 ] || RC=1
  verdict "fail-$1-rebooted (three tries, each counted and rebooted 10 s after its failure:$DELAYS s)" $RC
  fallback_after "$1"
  check_reboot_skipped "update-reboot-skipped-after-$1-fallback"
  activate_never
}

# failed_trace MARK: the failed-boot counter's lines in the serial log after byte MARK, one per
# line, from the first crash of the test unit on: the crash, the kernel's reboot, the counter
failed_trace() {
  tail -c +"$(($1 + 1))" "$SERIAL_LOG" | tr -d '\033\r' \
    | grep -ao "boot-test: crash PID 1 ([0-9.]*)\|reboot: Restarting system\|golconda-failed-boots: .*" \
    | sed -n '/^boot-test: crash/,$p' || true
}

# crash_line VERSION: the trace of one crash of VERSION that PID 1 rebooted (CrashAction=reboot)
crash_line() { echo "boot-test: crash PID 1 ($1)"; echo "reboot: Restarting system"; }

# halted_crash: since MARK, the sixth failed boot reboots on no failure, and its crash of
# LATER_VERSION is the last line (no reboot after it)
halted_crash() {
  HT=$(failed_trace "$MARK")
  echo "$HT" | grep -q "reboots on no failure" &&
    [ "$(echo "$HT" | tail -1)" = "boot-test: crash PID 1 ($LATER_VERSION)" ]
}

# failed_count_gone: the counter's variable is gone, golconda-failed-boots-complete.service ran
failed_count_gone() {
  wait_for 60 guest_active golconda-failed-boots-complete.service
  guest "! ls /sys/firmware/efi/efivars/GolcondaFailedBoots-* 2>/dev/null"
}

# wait_blessed: wait until systemd-bless-boot.service ran on this boot
wait_blessed() {
  wait_for 60 guest_active systemd-bless-boot.service
}

# test_fail_blessed: the failed-boot counter (docs/design/boot.md, "Failed boots") on a blessed
# entry, which boot counting does not count. $NEXT_VERSION crashes PID 1 on every boot: the fourth
# boot starts $OLD_VERSION once, which completes and marks $NEXT_VERSION bad (+0-3), so the reboot
# timer finds nothing to activate. A later release ($LATER_VERSION) is tried as usual; then it and
# $OLD_VERSION crash, and the seventh boot in a row reboots on no failure.
test_fail_blessed() {
  echo ""
  echo "=== failed boots: the blessed $NEXT_VERSION crashes PID 1 on every boot ==="
  LATER_NAME=$(basename "$(ls "$LATER_RELEASE"/*.efi)" .efi)
  LATER_VERSION=${LATER_NAME##*_}
  RC=0
  wait_blessed || RC=1
  D=$(guest ls /boot/EFI/Linux 2>&1) || true
  echo "$D"
  echo "$D" | grep -qxF "${IMAGE_ID}_$NEXT_VERSION.efi" || RC=1
  failed_count_gone || RC=1
  verdict "next-blessed ($NEXT_VERSION's UKI has no counter, the failed-boot count is reset)" $RC

  MARK=$(wc -c < "$SERIAL_LOG")
  guest "mkdir -p /var/lib/boot-test && touch /var/lib/boot-test/crash-$NEXT_VERSION && sync" || true
  guest systemctl reboot 2>&1 || true
  if ! wait_for_old "$BOOT_ID"; then
    verdict "failed-boots-fallback (no login of $OLD_VERSION before the timeout)" 1
    failed_trace "$MARK"
    return 1
  fi
  RC_GONE=0
  failed_count_gone || RC_GONE=1
  T=$(failed_trace "$MARK")
  echo "the crashes and the counter's lines on the serial console:"
  echo "$T"
  F="golconda-failed-boots: failed boots in a row:"
  E=$(
    crash_line "$NEXT_VERSION"
    echo "$F 1"
    crash_line "$NEXT_VERSION"
    echo "$F 2"
    echo "golconda-failed-boots: the next boot starts ${IMAGE_ID}_$OLD_VERSION.efi once"
    crash_line "$NEXT_VERSION"
    echo "$F 3"
    echo "golconda-failed-boots: ${IMAGE_ID}_$NEXT_VERSION.efi failed 3 boots in a row: marked bad, ${IMAGE_ID}_$NEXT_VERSION+0-3.efi"
    echo "golconda-failed-boots: this boot completed after 3 failed boots: the count is reset"
  )
  RC=0
  [ "$T" = "$E" ] || { RC=1; printf 'expected:\n%s\n' "$E"; }
  verdict "failed-boots-fallback (3 crashes of the blessed $NEXT_VERSION, each rebooted and counted; the fourth boot ran $V)" $RC
  verdict "failed-boots-reset ($V completed: the count is gone)" $RC_GONE

  D=$(guest ls /boot/EFI/Linux 2>&1) || true
  L=$(guest bootctl list --no-pager 2>&1) || true
  echo "$D"
  echo "$L" | grep -E " (title|tries):" || true
  RC=0
  echo "$D" | grep -qxF "${IMAGE_ID}_$NEXT_VERSION+0-3.efi" || RC=1
  ! echo "$D" | grep -qxF "${IMAGE_ID}_$NEXT_VERSION.efi" || RC=1
  echo "$L" | grep -q "title: Golconda $OLD_VERSION (default) (selected)" || RC=1
  echo "$L" | grep -q "tries: 0 left; 3 done" || RC=1
  verdict "failed-boots-marked-bad ($NEXT_VERSION's UKI is +0-3, systemd-boot's default is the running $OLD_VERSION)" $RC
  # the timer fires every 10 s: golconda-update-pending must find nothing to activate
  activate_soon || true
  check_reboot_skipped update-reboot-skipped-after-failed-boots
  activate_never
  RC=0
  guest "! ls /sys/firmware/efi/efivars/LoaderEntryOneShot-* 2>/dev/null" || RC=1
  reboot_guest || return 1
  V=$(guest_version)
  [ "$V" = "$OLD_VERSION" ] || RC=1
  verdict "failed-boots-fallback-holds (no one-shot set; a reboot starts $V)" $RC

  echo "--- a later release, $LATER_VERSION, is installed and tried ---"
  serve_release "$LATER_RELEASE" || return 1
  RC=0
  guest systemctl start --wait systemd-sysupdate-update.service || RC=1
  J=$(guest journalctl -b -u systemd-sysupdate-update.service -o cat --no-pager 2>&1) || true
  echo "$J" | grep "Successfully installed" || true
  echo "$J" | grep -q "Successfully installed 'http://$UPDATE_ADDR:$HTTP_PORT/${IMAGE_ID}_$LATER_VERSION" || RC=1
  D=$(guest ls /boot/EFI/Linux 2>&1) || true
  echo "$D"
  echo "$D" | grep -qxF "${IMAGE_ID}_$LATER_VERSION+3-0.efi" || RC=1
  echo "$D" | grep -qxF "${IMAGE_ID}_$OLD_VERSION.efi" || RC=1
  verdict "later-release-installed ($LATER_VERSION, with three tries, beside the running $OLD_VERSION)" $RC
  MARK=$(wc -c < "$SERIAL_LOG")
  activate_soon || true
  RC=0
  wait_for_ssh "$BOOT_ID" || RC=1
  V=$(guest_version)
  [ "$V" = "$LATER_VERSION" ] || RC=1
  trial_trace "$MARK" | grep -qxF "golconda-trial-boot: ${IMAGE_ID}_$LATER_VERSION+2-1.efi is on trial" || RC=1
  wait_blessed || RC=1
  failed_count_gone || RC=1
  activate_never
  verdict "later-release-tried (the reboot timer started $V's first try, which was blessed)" $RC

  echo "--- $LATER_VERSION and $OLD_VERSION crash ---"
  MARK=$(wc -c < "$SERIAL_LOG")
  guest "touch /var/lib/boot-test/crash-$LATER_VERSION /var/lib/boot-test/crash-$OLD_VERSION && sync" || true
  guest systemctl reboot 2>&1 || true
  # until the halted boot's crash, then 20 s without a reboot: more than PID 1's 10 s
  wait_for "$TIMEOUT" halted_crash
  sleep 20
  T=$(failed_trace "$MARK")
  echo "$T"
  E=$(
    crash_line "$LATER_VERSION"
    echo "$F 1"
    crash_line "$LATER_VERSION"
    echo "$F 2"
    echo "golconda-failed-boots: the next boot starts ${IMAGE_ID}_$OLD_VERSION.efi once"
    crash_line "$LATER_VERSION"
    echo "$F 3"
    crash_line "$OLD_VERSION"
    echo "$F 4"
    crash_line "$LATER_VERSION"
    echo "$F 5"
    crash_line "$LATER_VERSION"
    echo "$F 6: this boot reboots on no failure (kernel.panic=0, CrashAction=freeze, no watchdog)"
    echo "boot-test: crash PID 1 ($LATER_VERSION)"
  )
  RC=0
  qemu_running || RC=1
  [ "$T" = "$E" ] || { RC=1; printf 'expected:\n%s\n' "$E"; }
  verdict "failed-boots-halt (both slots crash: the fourth boot ran $OLD_VERSION once, the seventh crashed and nothing rebooted it for 20 s)" $RC
  stop_qemu
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

# test_verity_keyring: dm-verity checks the signed root hash of the slot sysupdate just filled
# against the kernel's built-in certificate, never the firmware's db (docs/design/trust.md). A
# plain --next is signed with that key and activates the volume; under --rotate it is signed with
# the new db key, which the running kernel does not carry, so the kernel refuses it (ENOKEY) and
# veritysetup activates the volume unsigned. A signed activation shows no "retrying without".
test_verity_keyring() {
  echo ""
  echo "=== the kernel's verity keyring: the signature of $NEXT_VERSION's /usr ==="
  SIG_JSON=$(guest "cat /dev/disk/by-partlabel/usr-verity-sig_$NEXT_VERSION" | tr -d '\000') || true
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
  # the host filters the kernel's messages
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
# check_enable_kept: `systemctl enable` before the update linked the unit's path in /usr, not a
# store path, so the link resolves in the next release and the unit is enabled. The harness then
# disables it: units-composed-only-after-update checks an /etc without links
ENABLE_UNIT=remote-fs.target
ENABLE_LINK=/etc/systemd/system/multi-user.target.wants/$ENABLE_UNIT
check_enable_kept() {
  echo ""
  echo "=== an enable link across the update ==="
  RC=0
  T=$(guest readlink "$ENABLE_LINK" 2>&1) || RC=1
  E=$(guest systemctl is-enabled "$ENABLE_UNIT" 2>&1) || RC=1
  guest test -f "$ENABLE_LINK" || RC=1
  echo "$ENABLE_LINK -> ${T:-none}; is-enabled: ${E:-none}"
  [ "$T" = "/usr/lib/systemd/system/$ENABLE_UNIT" ] && [ "$E" = enabled ] || RC=1
  verdict "enable-kept-after-update ($ENABLE_UNIT, enabled before the update: the link names /usr, resolves, and the unit is enabled)" $RC
  guest systemctl disable "$ENABLE_UNIT" || true
}

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
  # --rotate: the next release's loader and UKI are signed with the new db key, so PCR 7 changes
  # at its first boot; the rotation procedure seals the vars without PCR 7 first
  if [ "$ROTATE" = 1 ] && [ "$TPM" = 1 ]; then
    reseal_vars vars-resealed-without-pcr7 --without-pcr7
  fi

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

  check_reboot_window
  if [ "$FAIL_PANIC" = 1 ] || [ "$FAIL_PID1" = 1 ]; then
    if [ "$FAIL_PANIC" = 1 ]; then test_fail_tries panic; else test_fail_tries pid1; fi || return 1
    check_no_failed no-failed-units-after-update
    return 0
  fi
  if [ "$FAIL_INITRD" = 1 ]; then
    test_fail_initrd || return 1
    check_no_failed no-failed-units-after-update
    return 0
  fi
  if [ "$FAIL_HEALTH" = 1 ]; then
    # no blessed boot of the candidate, so no loader and no recovery checks here
    test_fail_health || return 1
    check_units_composed -after-fallback
    check_no_failed no-failed-units-after-update
    return 0
  fi
  # an operator's enable link, made before the update, for check_enable_kept
  guest systemctl enable "$ENABLE_UNIT" || true
  echo "Waiting for the reboot timer to activate $NEXT_VERSION..."
  activate_soon || true
  if ! wait_for_ssh "$BOOT_ID"; then
    verdict "update-activated (no login after the activation before the timeout)" 1
    return 1
  fi
  V=$(guest_version)
  RC=0; [ "$V" = "$NEXT_VERSION" ] || RC=1
  verdict "update-activated (the reboot timer rebooted into $V; the harness rebooted nothing)" $RC
  verdict "boots-next ($OLD_VERSION -> $V)" $RC
  check_reboot_skipped update-reboot-skipped
  activate_never
  if [ "$FAIL_BLESSED" = 1 ]; then
    # the run ends on a halted machine: no loader and no recovery checks
    test_fail_blessed
    return
  fi
  check_unsealed "after the update to $V"
  check_enable_kept
  check_units_composed -after-update
  check_no_failed no-failed-units-after-update
  check_clock clock-not-reset-after-update
  check_hwdb hwdb-after-update
  check_dm_usr dm-usr-device-after-update
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

  test_recovery || return 1
  [ -z "$LATER" ] || test_first_slot
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
  # on the old slot systemd-boot's default is the new one, so the reboot timer would activate it:
  # masked while the harness boots slots by hand, whatever the hour
  guest "ln -sf /dev/null /etc/systemd/system/systemd-sysupdate-reboot.timer" || true
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
  guest "rm -f /etc/systemd/system/systemd-sysupdate-reboot.timer && systemctl daemon-reload" || true

  echo ""
  echo "=== recovery: the firmware menu ==="
  FW_MARK=$(wc -c < "$SERIAL_LOG")
  guest bootctl reboot-to-firmware true 2>&1 || true
  guest bootctl reboot-to-firmware 2>&1 || true
  guest systemctl reboot 2>&1 || true
  FW=0
  wait_for 45 firmware_menu || FW=1
  # OVMF (edk2-stable202408) draws its front page with cursor moves; the item texts are plain runs
  tail -c +"$((FW_MARK + 1))" "$SERIAL_LOG" \
    | grep -ao "Please select boot device:\|Device Manager\|Boot Maintenance Manager\|UEFI [A-Za-z0-9 ]*Device" | sort -u || true
  verdict "reboot-to-firmware (OVMF's boot menu on the serial console)" $FW
}

# --- --next --later: a third release into the first release's slot ---
# slot_of LABEL: the device of the partition LABEL, nothing when no partition has it
slot_of() {
  guest "p=/dev/disk/by-partlabel/$1; [ ! -e \$p ] || readlink -f \$p" 2>/dev/null || true
}

# test_first_slot: after the recovery paths (the machine is in the firmware menu), power on: the
# second release runs from the slot the update filled. sysupdate must put $LATER_VERSION into the
# slot of $OLD_VERSION, the one the disk image made, and the reboot timer must start it from there.
test_first_slot() {
  LATER_NAME=$(basename "$(ls "$LATER_RELEASE"/*.efi)" .efi)
  LATER_VERSION=${LATER_NAME##*_}
  echo ""
  echo "=== a third release, $LATER_VERSION, into the first release's slot ==="
  stop_qemu
  SERIAL_LOG=$WORKDIR/serial-later.log
  rotate_tpm
  start_qemu
  if ! wait_for_ssh ""; then
    verdict "update-into-first-slot (no login after the power-on before the timeout)" 1
    return 1
  fi
  V=$(guest_version)
  SLOT_A=$(slot_of "usr_$OLD_VERSION")
  SLOT_A_VERITY=$(slot_of "usr-verity_$OLD_VERSION")
  SLOT_B=$(slot_of "usr_$NEXT_VERSION")
  echo "running $V; usr_$OLD_VERSION: ${SLOT_A:-none}, usr_$NEXT_VERSION: ${SLOT_B:-none}"
  RC=0
  { [ "$V" = "$NEXT_VERSION" ] && [ -n "$SLOT_A" ] && [ -n "$SLOT_A_VERITY" ] && [ -n "$SLOT_B" ]; } || RC=1
  serve_release "$LATER_RELEASE" || return 1
  guest systemctl start --wait systemd-sysupdate-update.service || RC=1
  J=$(guest journalctl -b -u systemd-sysupdate-update.service -o cat --no-pager 2>&1) || true
  echo "$J" | grep "Successfully installed" || true
  echo "$J" | grep -q "Successfully installed 'http://$UPDATE_ADDR:$HTTP_PORT/${IMAGE_ID}_$LATER_VERSION" || RC=1
  echo "usr_$LATER_VERSION: $(slot_of "usr_$LATER_VERSION"), usr-verity_$LATER_VERSION: $(slot_of "usr-verity_$LATER_VERSION")"
  [ "$(slot_of "usr_$LATER_VERSION")" = "$SLOT_A" ] || RC=1
  [ "$(slot_of "usr-verity_$LATER_VERSION")" = "$SLOT_A_VERITY" ] || RC=1
  [ -z "$(slot_of "usr_$OLD_VERSION")" ] || RC=1
  [ "$(slot_of "usr_$NEXT_VERSION")" = "$SLOT_B" ] || RC=1
  verdict "update-into-first-slot ($LATER_VERSION into $SLOT_A, the partition labelled usr_$OLD_VERSION before; $NEXT_VERSION keeps $SLOT_B)" $RC

  activate_soon || true
  RC=0
  wait_for_ssh "$BOOT_ID" || RC=1
  V=$(guest_version)
  [ "$V" = "$LATER_VERSION" ] || RC=1
  wait_blessed || RC=1
  activate_never
  # /usr's verity device sits on the first slot's partitions
  DM=$(guest 'ls /sys/block/$(basename $(readlink -f /dev/mapper/usr))/slaves' 2>&1) || true
  echo "/dev/mapper/usr over: $(echo "$DM" | tr '\n' ' ')"
  echo "$DM" | grep -qx "${SLOT_A#/dev/}" || RC=1
  L=$(guest bootctl list --no-pager 2>&1) || true
  echo "$L" | grep -E " (title|id):" || true
  echo "$L" | grep -q "title: Golconda $LATER_VERSION (default) (selected)" || RC=1
  echo "$L" | grep -q "id: ${IMAGE_ID}_$NEXT_VERSION.efi" || RC=1
  ! echo "$L" | grep -q "id: ${IMAGE_ID}_$OLD_VERSION.efi" || RC=1
  verdict "boots-first-slot ($V from $SLOT_A, blessed; bootctl: $LATER_VERSION selected, $NEXT_VERSION kept, $OLD_VERSION gone)" $RC
}

# firmware_menu: OVMF's boot menu is on the serial console after byte FW_MARK
firmware_menu() {
  tail -c +"$((FW_MARK + 1))" "$SERIAL_LOG" | grep -aq "Boot Maintenance Manager"
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
  # with --tpm two boots: the rotated one, and the one after the reseal
  TIMEOUT=$((TPM == 1 ? 420 : 240))
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
  # the last step of the procedure: db and dbx hold their new values, so PCR 7 does too
  if [ "$TPM" = 1 ]; then
    reseal_vars vars-resealed-pcr7
    reboot_guest || return 1
    check_unsealed "after the rotation, sealed to the new PCR 7"
  fi
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
