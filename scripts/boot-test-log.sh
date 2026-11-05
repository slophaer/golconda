# Serial boot decisions only. Sourcing this file starts no processes.
# wait_for_boot uses the caller's SERIAL_LOG and qemu_running function.

serial_marker_present() {
  case "$1" in
    multi-user-reached) pattern='Reached target[[:space:]]+(Multi-User System|multi-user[.]target)([[:space:].]|$)' ;;
    sshd-active) pattern='sshd.*Listening|Started.*sshd|Started.*OpenSSH' ;;
    var-sshd-hostkey) pattern='Finished.*Generate var sshd-hostkey' ;;
    boot-complete) pattern='Reached target[[:space:]]+(Boot Complete|Boot Completion Check|boot-complete[.]target)([[:space:].]|$)' ;;
    # /etc is read-only, so no boot is a first boot and systemd-firstboot is skipped (the ssh
    # test checks that); the serial log must show no prompt of any kind
    no-prompt)
      ! grep -qi 'Please enter' "$2" 2>/dev/null
      return
      ;;
    *) return 1 ;;
  esac
  # systemd colours target names on the serial console. Remove only SGR sequences.
  sed "s/$(printf '\033')\[[0-9;]*m//g" "$2" 2>/dev/null | grep -Eqi "$pattern"
}

serial_boot_ready() {
  for marker in multi-user-reached sshd-active var-sshd-hostkey boot-complete no-prompt; do
    serial_marker_present "$marker" "$1" || return 1
  done
}

# Wait for every required marker, not just multi-user. The caller owns the timeout.
wait_for_boot() {
  while qemu_running; do
    if serial_boot_ready "$SERIAL_LOG"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# --- check markers (positive evidence only) ---
check_markers() {
  PASS=0
  FAIL=0

  echo ""
  echo "=== Marker checks (serial log) ==="

  for marker in multi-user-reached sshd-active var-sshd-hostkey boot-complete no-prompt; do
    if serial_marker_present "$marker" "$SERIAL_LOG"; then
      echo "PASS: $marker"
      PASS=$((PASS + 1))
    else
      echo "FAIL: $marker (required success evidence missing or an interactive prompt appeared)"
      FAIL=$((FAIL + 1))
    fi
  done

  echo ""
  echo "=== Summary ==="
  echo "PASS: $PASS, FAIL: $FAIL"

  [ "$FAIL" -eq 0 ]
}
