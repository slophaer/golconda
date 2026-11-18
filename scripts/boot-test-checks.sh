# shellcheck shell=sh
# Part of scripts/boot-test, sourced by it (no processes start when sourced).
# The checks: each is one function that every mode that needs it calls (docs/release-checklist.md).

# vars CMD...: `golconda vars` against this guest, as an operator runs it: an ssh
# config names the guest boot-test, the store is $WORKDIR/vars, encrypted to a fresh age key
vars() {
  GOLCONDA_SSH="ssh -F $WORKDIR/ssh/config" "$GOLCONDA" vars "$@"
}

# push_admin_vars: sign the guest's host key with the host CA once its fingerprint matches the
# first boot's console line, store the certificate and a KRL naming cert-revoked with golconda
# vars, and push them. --next reads the key with `golconda vars pub` first; --enrol checks a
# wrong fingerprint first. Both then run `golconda vars enrol`. From
# then on a release with hostCertificate on refuses plain keys, so the harness also offers the
# certificate cert-admin (GUEST_EXTRA_ID)
push_admin_vars() {
  echo ""
  echo "=== admin vars: the host certificate and the revocation list, with golconda vars ==="
  cat > "$WORKDIR/ssh/config" <<EOF
Host boot-test
  HostName localhost
  Port $SSH_PORT
  User root
  IdentityFile $WORKDIR/ssh/user
  IdentityFile $WORKDIR/ssh/cert-admin
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF
  mkdir -p "$WORKDIR/vars"
  age-keygen -o "$WORKDIR/age.key" 2>/dev/null
  age-keygen -y "$WORKDIR/age.key" > "$WORKDIR/vars/recipients.txt"
  cp "$REPO_DIR/tests/fixtures/snakeoil-host-ca" "$WORKDIR/ssh/host-ca"
  chmod 600 "$WORKDIR/ssh/host-ca"
  echo "serial: 3" > "$WORKDIR/ssh/krl.spec"
  ssh-keygen -q -k -f "$WORKDIR/ssh/krl" -s "$REPO_DIR/tests/fixtures/snakeoil-user-ca.pub" "$WORKDIR/ssh/krl.spec"
  if [ "$ENROL" = 1 ]; then
    enrol_admin_vars
  else
    # the operator's check before signing: the key golconda vars reads over ssh is the key whose
    # fingerprint the machine printed on its serial console at first boot (modules/services/sshd)
    RC=0
    (cd "$WORKDIR" && vars pub boot-test sshd-hostkey key.pub) > "$WORKDIR/ssh/host.pub" || RC=1
    FP=$(ssh-keygen -l -f "$WORKDIR/ssh/host.pub" 2>/dev/null | cut -d' ' -f2) || FP=""
    echo "host key fingerprint: ${FP:-none}"
    grep -a "golconda: ssh host key" "$FIRST_SERIAL_LOG" | tail -1 || true
    [ -n "$FP" ] && grep -aq "golconda: ssh host key .*$FP" "$FIRST_SERIAL_LOG" || RC=1
    verdict "hostkey-fingerprint-on-console (the key golconda vars pub reads is the one the console names)" $RC
    RC=0
    (
      cd "$WORKDIR" || exit 1
      vars enrol -i age.key boot-test --ca-key ssh/host-ca --principal localhost --krl ssh/krl \
        --fingerprint "$FP"
    ) > "$WORKDIR/push.out" 2>&1 || RC=1
  fi
  cat "$WORKDIR/push.out"
  GUEST_EXTRA_ID="-i $WORKDIR/ssh/cert-admin"
  grep -qx "sealed sshd-host-cert.cert" "$WORKDIR/push.out" || RC=1
  grep -qx "sealed sshd-revoked-keys.krl" "$WORKDIR/push.out" || RC=1
  grep -qx "restarted sshd.service" "$WORKDIR/push.out" || RC=1
  verdict "admin-vars-pushed (host certificate and KRL stored, pushed, sshd restarted)" $RC
  LIST=$(cd "$WORKDIR" && vars list boot-test 2>&1) || true
  echo "$LIST"
  RC=0
  echo "$LIST" | grep -qx "sshd-host-cert cert stored sealed" || RC=1
  echo "$LIST" | grep -qx "sshd-revoked-keys krl stored sealed" || RC=1
  verdict "admin-vars-sealed (golconda vars list: stored here, sealed there)" $RC
}

# enrol_admin_vars: `golconda vars enrol` as an operator runs it (docs/features/ssh-login.md). A
# fingerprint that is not the console's must be refused before anything is signed, stored or
# sealed. Leaves RC, the command's result, for admin-vars-pushed.
enrol_admin_vars() {
  CONSOLE_FP=$(grep -a "golconda: ssh host key" "$FIRST_SERIAL_LOG" | tail -1 |
    grep -o 'SHA256:[A-Za-z0-9+/]*') || CONSOLE_FP=""
  echo "console: host key ${CONSOLE_FP:-none}"
  RC=0
  if (cd "$WORKDIR" && vars enrol -i age.key boot-test --ca-key ssh/host-ca --principal localhost \
    --krl ssh/krl --fingerprint SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA) \
    > "$WORKDIR/enrol-wrong.out" 2>&1; then
    RC=1
  fi
  cat "$WORKDIR/enrol-wrong.out"
  grep -q "nothing is signed, stored or pushed" "$WORKDIR/enrol-wrong.out" || RC=1
  LIST=$(cd "$WORKDIR" && vars list boot-test 2>&1) || RC=1
  echo "$LIST"
  if echo "$LIST" | grep -q -e " stored " -e " sealed$"; then RC=1; fi
  verdict "enrol-wrong-fingerprint-refused (golconda vars enrol: a fingerprint not the console's stores and seals nothing)" $RC
  ENROL_RC=0
  (
    cd "$WORKDIR" || exit 1
    vars enrol -i age.key boot-test --ca-key ssh/host-ca --principal localhost --krl ssh/krl \
      --fingerprint "$CONSOLE_FP"
  ) > "$WORKDIR/push.out" 2>&1 || ENROL_RC=1
  RC=0
  [ -n "$CONSOLE_FP" ] && grep -q "^host key .* $CONSOLE_FP " "$WORKDIR/push.out" || RC=1
  verdict "hostkey-fingerprint-on-console (golconda vars enrol read the key the console names)" $RC
  RC=$ENROL_RC
}

# test_certs LOGIN: the release presents the host certificate, takes a good user certificate (the
# check LOGIN), refuses the revoked one, and takes effect of a second KRL when sshd restarts
test_certs() {
  echo ""
  echo "=== certificates: $1 ==="
  RC=0
  host_cert_login || RC=1
  verdict "host-cert-presented (the host CA vouches for the key; strict known_hosts)" $RC
  expect_login "$1" ok 0
  expect_login "cert-revoked-refused (the KRL names serial 3)" revoked 1

  echo "serial: 1" >> "$WORKDIR/ssh/krl.spec"
  RC=0
  (
    cd "$WORKDIR" || exit 1
    ssh-keygen -q -k -f ssh/krl -s "$REPO_DIR/tests/fixtures/snakeoil-user-ca.pub" ssh/krl.spec
    vars set boot-test sshd-revoked-keys krl < ssh/krl
    vars push -i age.key boot-test sshd-revoked-keys
  ) || RC=1
  verdict "krl-pushed-again (rotation: set and push)" $RC
  expect_login "krl-rotated (the good certificate is refused once the new KRL names it)" ok 1
}

# host_cert_login: log in with the certificate cert-admin, trusting only the host CA (strict
# known_hosts)
host_cert_login() {
  echo "@cert-authority localhost,[localhost]:$SSH_PORT $(cat "$REPO_DIR/tests/fixtures/snakeoil-host-ca.pub")" \
    > "$WORKDIR/known_hosts_ca"
  # shellcheck disable=SC2086
  ssh $SSH_OPTS -o UserKnownHostsFile="$WORKDIR/known_hosts_ca" -o StrictHostKeyChecking=yes \
    -o HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com -o IdentitiesOnly=yes \
    -i "$WORKDIR/ssh/cert-admin" root@localhost true
}

# bootstrap_login: the plain bootstrap key of the SMBIOS credential (--enrol)
bootstrap_login() {
  # shellcheck disable=SC2086
  ssh $SSH_OPTS $NO_HOSTKEY_CHECK -o IdentitiesOnly=yes -i "$WORKDIR/ssh/bootstrap" root@localhost true
}

# check_plain_refused NAME: neither plain key (the SMBIOS credential's, the image's test key) logs
# in: the KRL names neither, so the refusal is the enrolment's. Each refusal costs the QEMU gateway
# address 5 s of sshd's PerSourcePenalties, and 15 s block it, so each starts after the last
# penalty ran out.
check_plain_refused() {
  RC=0
  sleep 6
  if bootstrap_login 2>/dev/null; then RC=1; fi
  sleep 6
  # shellcheck disable=SC2086
  if ssh $SSH_OPTS $NO_HOSTKEY_CHECK -o IdentitiesOnly=yes -i "$WORKDIR/ssh/user" root@localhost true 2>/dev/null; then
    RC=1
  fi
  sleep 6
  verdict "$1 (the bootstrap key and the image's test key are refused; the KRL names neither)" $RC
}

# test_enrol: one release from first boot to certificates (docs/design/trust.md, "Identity"):
# push the host certificate and a KRL, then the same boot presents the certificate, takes
# certificates, refuses the revoked one and every plain key, and takes a rotated KRL.
test_enrol() {
  ENROL_VERSION=$(guest_version)
  push_admin_vars
  test_certs cert-login-after-enrol
  check_plain_refused bootstrap-key-refused-after-enrol
  RC=0
  B=$(guest cat /proc/sys/kernel/random/boot_id 2>/dev/null) || B=""
  [ "$B" = "$FIRST_BOOT_ID" ] && [ -n "$ENROL_VERSION" ] && [ "$(guest_version)" = "$ENROL_VERSION" ] || RC=1
  verdict "enrol-one-release (all of it in the first boot of ${ENROL_VERSION:-?}: no update, no reboot)" $RC
}

# test_enrol_after_reboot: the sealed certificate and KRL unseal after a reboot (--enrol --tpm):
# cert-admin logs in (the image's fallback list would refuse it), the rotated KRL still refuses the
# good certificate, and plain keys stay refused
test_enrol_after_reboot() {
  echo ""
  echo "=== certificates after the reboot ==="
  RC=0
  host_cert_login || RC=1
  verdict "host-cert-presented-after-reboot (cert-admin logs in: the pushed KRL, not the fallback)" $RC
  expect_login "cert-revoked-refused-after-reboot (the rotated KRL names serial 1)" ok 1
  check_plain_refused bootstrap-key-refused-after-reboot
}

# test_reenrol_after_reset: --enrol --factory-reset (docs/features/factory-reset.md). The reset
# took the sealed certificate and KRL, and the machine made a new host key, so the harness logs in
# with a plain key; `golconda vars enrol` refuses the first boot's fingerprint and enrols the new.
test_reenrol_after_reset() {
  echo ""
  echo "=== after the factory reset: golconda vars enrol again ==="
  RC=0
  if cert_login ok 2>/dev/null; then RC=1; fi
  verdict "cert-refused-after-reset (revokedKeys: the KRL went with the state, the fallback list refuses the user CA)" $RC
  sleep 6
  RC=0
  if (cd "$WORKDIR" && vars enrol -i age.key boot-test --ca-key ssh/host-ca --principal localhost \
    --krl ssh/krl --fingerprint "$FIRST_FP") > "$WORKDIR/reenrol-old.out" 2>&1; then
    RC=1
  fi
  cat "$WORKDIR/reenrol-old.out"
  grep -q "nothing is signed, stored or pushed" "$WORKDIR/reenrol-old.out" || RC=1
  verdict "reenrol-old-fingerprint-refused (the first boot's fingerprint ${FIRST_FP:-none} is not the new key's)" $RC
  RC=0
  (
    cd "$WORKDIR" || exit 1
    vars enrol -i age.key boot-test --ca-key ssh/host-ca --principal localhost --krl ssh/krl \
      --fingerprint "$RESET_FP"
  ) > "$WORKDIR/reenrol.out" 2>&1 || RC=1
  cat "$WORKDIR/reenrol.out"
  [ -n "$RESET_FP" ] && grep -q "^host key .* $RESET_FP " "$WORKDIR/reenrol.out" || RC=1
  grep -qx "sealed sshd-host-cert.cert" "$WORKDIR/reenrol.out" || RC=1
  grep -qx "sealed sshd-revoked-keys.krl" "$WORKDIR/reenrol.out" || RC=1
  grep -qx "restarted sshd.service" "$WORKDIR/reenrol.out" || RC=1
  verdict "reenrol-after-reset (golconda vars enrol with the reset boot's console fingerprint: certificate and KRL sealed, sshd restarted)" $RC
  RC=0
  host_cert_login || RC=1
  verdict "host-cert-presented-after-reset (the new host key's certificate; cert-admin logs in)" $RC
  check_plain_refused bootstrap-key-refused-after-reenrol
}

# check_hwdb NAME: lookups answer from the hardware database compiled into /usr (packages/hwdb):
# the IMDS entry for Hetzner Cloud, and PCI and USB names. Each image carries its own, so it runs
# on the first release and the one an update installed.
check_hwdb() {
  echo ""
  echo "=== $1 ==="
  RC=0
  Q=$(guest systemd-hwdb query dmi:bvnHetzner: 2>&1) || RC=1
  echo "$Q"
  echo "$Q" | grep -q "^IMDS_VENDOR=hetzner-cloud$" || RC=1
  P=$(guest systemd-hwdb query pci:v00001AF4d00001000 2>&1) || RC=1
  U=$(guest systemd-hwdb query usb:v1D6Bp0002 2>&1) || RC=1
  echo "$P"; echo "$U"
  echo "$P" | grep -q "^ID_VENDOR_FROM_DATABASE=Red Hat, Inc.$" || RC=1
  echo "$U" | grep -q "^ID_VENDOR_FROM_DATABASE=Linux Foundation$" || RC=1
  guest test -e /usr/lib/udev/hwdb.bin || RC=1
  guest test ! -e /etc/udev/hwdb.bin || RC=1
  verdict "$1 (/usr/lib/udev/hwdb.bin answers for DMI, PCI and USB; none in /etc)" $RC
}

# check_hang_panic: a hang reboots (docs/design/boot.md, "Trial boot"). The lockup and hung task
# detectors panic (the cmdline's *_panic=1), a panic reboots after 10 s, and PID 1 runs the hardware
# watchdog with a 30 s timeout: QEMU's i6300esb (-device i6300esb), not softdog
check_hang_panic() {
  echo ""
  echo "=== hangs become panics; the watchdog ==="
  S=$(guest 'for k in panic softlockup_panic hardlockup_panic hung_task_panic; do echo "$k=$(cat /proc/sys/kernel/$k)"; done' 2>&1) || true
  echo "$S"
  RC=0
  for k in panic=10 softlockup_panic=1 hardlockup_panic=1 hung_task_panic=1; do
    echo "$S" | grep -qx "$k" || RC=1
  done
  verdict "hang-panic-sysctls (kernel.panic=10; a soft or hard lockup and a hung task panic)" $RC
  W=$(guest 'd=/sys/class/watchdog/watchdog0; for f in identity state timeout; do echo "$f=$(cat $d/$f)"; done; systemctl show -p RuntimeWatchdogUSec -p RebootWatchdogUSec' 2>&1) || true
  echo "$W"
  RC=0
  echo "$W" | grep -qx 'identity=i6300ESB timer' || RC=1
  echo "$W" | grep -qx 'state=active' || RC=1
  echo "$W" | grep -qx 'timeout=30' || RC=1
  echo "$W" | grep -qx 'RebootWatchdogUSec=10min' || RC=1
  verdict "watchdog-armed (watchdog0 is the i6300esb, active, timeout 30 s; 10 min for a reboot)" $RC
}

# check_units_composed [SUFFIX]: every enabled unit has a static link in a .wants, .requires or
# .upholds directory of /usr/lib/systemd/system (docs/design/layout.md, "Unit enablement"), because
# 00-golconda.preset says `disable *` and nothing writes to /etc/systemd/system. The generators'
# links in /run (enabled-runtime) are not counted. SUFFIX names a later boot (-after-update).
check_units_composed() {
  echo ""
  echo "=== enabled units${1:+ ($1)} ==="
  RC=0
  L=$(guest 'for f in /etc/systemd/system/* /etc/systemd/system/*/*; do [ -L "$f" ] && echo "$f -> $(readlink "$f")"; done; true') || L="no answer"
  echo "links in /etc/systemd/system: ${L:-none}"
  [ -z "$L" ] || RC=1
  EN=$(guest systemctl list-unit-files --state=enabled --no-legend --no-pager 2>&1 | cut -d' ' -f1) || EN=""
  W=$(guest 'for f in /usr/lib/systemd/system/*.wants/* /usr/lib/systemd/system/*.requires/* /usr/lib/systemd/system/*.upholds/*; do echo "${f##*/}"; done') || W=""
  OUT=""
  for u in $EN; do
    case "$u" in
      *@.*) echo "$W" | grep -q "^${u%%@.*}@.*[.]${u##*.}$" && continue ;;
      *) echo "$W" | grep -qxF "$u" && continue ;;
    esac
    OUT="$OUT $u"
  done
  echo "enabled unit files: $(echo "$EN" | tr '\n' ' ')"
  echo "enabled without a link in /usr:${OUT:- none}"
  [ -z "$OUT" ] || RC=1
  verdict "units-composed-only${1:-} (no link in /etc/systemd/system; each enabled unit has a static link in /usr)" $RC

  RC=0
  X=$(guest systemctl list-unit-files --no-legend --no-pager '*sysext*' '*confext*' 2>&1) || true
  echo "sysext and confext units: ${X:-none}"
  [ -z "$X" ] || RC=1
  P=$(guest 'for f in /usr/bin/systemd-sysext /usr/bin/systemd-confext; do [ -e "$f" ] && echo "$f"; done; true') || P="no answer"
  echo "sysext and confext programs: ${P:-none}"
  [ -z "$P" ] || RC=1
  verdict "no-sysext${1:-} (no sysext or confext unit and no program)" $RC
}

# check_sshd_sockets: Golconda's sshd.service, with its sshd_config, is the only ssh server. systemd's
# ssh generator is not in the image (packages/systemd), so no sshd-*.socket listens on AF_UNIX or
# AF_VSOCK, or on an address an ssh.listen credential names, with a stock sshd that ignores
# Golconda's sshd_config; and the kernel has no AF_VSOCK
check_sshd_sockets() {
  echo ""
  echo "=== ssh servers ==="
  RC=0
  U=$(guest systemctl list-units --all --plain --no-legend --no-pager 'sshd*' 2>&1 | cut -d' ' -f1) || U="no answer"
  echo "sshd units: $(echo "$U" | tr '\n' ' ')"
  [ "$U" = sshd.service ] || RC=1
  S=$(guest systemctl list-sockets --all --no-legend --no-pager --full 2>&1 | grep -i ssh) || S=""
  echo "ssh sockets: ${S:-none}"
  [ -z "$S" ] || RC=1
  G=$(guest 'for f in /usr/lib/systemd/system-generators/systemd-ssh-generator /run/ssh-unix-local /dev/vsock; do [ -e "$f" ] && echo "$f"; done; true') || G="no answer"
  echo "generator, its socket directory, vsock: ${G:-none}"
  [ -z "$G" ] || RC=1
  verdict "sshd-golconda-only (sshd.service is the one ssh unit; no ssh socket, no ssh generator, no vsock)" $RC
}

# check_no_failed NAME: no unit has failed in the running boot
check_no_failed() {
  echo ""
  echo "=== systemctl --failed ($1) ==="
  FAILED=$(guest systemctl --failed --no-pager 2>&1) || true
  echo "$FAILED"
  RC=0; echo "$FAILED" | grep -q "^0 loaded units listed" || RC=1
  verdict "$1" $RC
}

# check_clock NAME: the clock the kernel read at boot was kept (every boot is checked, each under
# its NAME). PID 1 resets a clock more than 15 years past systemd's epoch, and until timesyncd
# syncs, DNSSEC and TLS times fail. Under KVM the guest reads the host's time (kvm-clock, not the
# RTC), so the journal must have no "further ahead than" reset message.
check_clock() {
  echo ""
  echo "=== the clock ($1) ==="
  RC=0
  EPOCH_YEAR=$(sed -n 's/^date = "\([0-9]*\)-.*/\1/p' "$REPO_DIR/packages/systemd/sources.toml")
  J=$(guest journalctl -b -o short-unix --no-pager -q 2>&1) || RC=1
  RESET=$(echo "$J" | grep -F "further ahead than" || true)
  FIRST=$(echo "$J" | sed -n 's/^\([0-9][0-9]*\)\..*/\1/p' | sort -n | head -1)
  YEAR=$(date -u -d "@${FIRST:-0}" +%Y 2>/dev/null) || YEAR=0
  echo "epoch year: ${EPOCH_YEAR:-unknown}; oldest journal entry of this boot: year $YEAR"
  [ -z "$RESET" ] || { echo "reset: $RESET"; RC=1; }
  [ -n "$EPOCH_YEAR" ] && [ "$YEAR" -ge "$EPOCH_YEAR" ] || RC=1
  verdict "$1 (no clock reset in the journal; no entry before $EPOCH_YEAR)" $RC
}

# The sealed sshd host key: a local var's credential (modules/lib/var.nix)
HOSTKEY_CRED=/etc/credstore.encrypted/sshd-hostkey.key

# check_unsealed WHEN: with --tpm, the host key the first boot sealed still opens, and nothing
# sealed it again. sshd presents the first boot's key (known_hosts, StrictHostKeyChecking=yes),
# the credential has the bytes the first boot wrote, and sshd runs. A new key would mean the var
# ran again; new bytes, that something re-sealed it.
check_unsealed() {
  [ "$TPM" = 1 ] || return 0
  RC=0
  # shellcheck disable=SC2086
  ssh $SSH_OPTS -o UserKnownHostsFile="$WORKDIR/known_hosts" -o StrictHostKeyChecking=yes \
    -i "$WORKDIR/ssh/user" $GUEST_EXTRA_ID root@localhost true || RC=1
  H=$(guest_hash "$HOSTKEY_CRED")
  [ -n "$H" ] && [ "$H" = "$SEALED_HASH" ] || RC=1
  A=$(guest systemctl is-active sshd.service 2>&1) || true
  [ "$A" = "active" ] || RC=1
  verdict "hostkey-unchanged ($1: the first boot's host key, credential not re-sealed, sshd $A)" $RC
}

# cred_pcrs FILE: the PCRs the sealed credential FILE in the guest is bound to, as "hashed=7
# signed=11" ("-" for none). It reads the TPM2 header of systemd's creds-util.c: the mask of the
# PCRs bound by value, then the public key header with the mask of the signed policy's PCRs.
cred_pcrs() {
  guest "base64 -d < $1" > "$WORKDIR/cred.bin" 2>/dev/null || : > "$WORKDIR/cred.bin"
  python3 - "$WORKDIR/cred.bin" <<'EOF'
import struct, sys
d = open(sys.argv[1], "rb").read()
def pcrs(m):
    return "+".join(str(i) for i in range(64) if m >> i & 1) or "-"
try:
    iv = struct.unpack_from("<I", d, 24)[0]
    p = (32 + iv + 7) & ~7
    hashed, _bank, _alg, blob, policy = struct.unpack_from("<QHHII", d, p)
    signed = struct.unpack_from("<Q", d, p + ((20 + blob + policy + 7) & ~7))[0]
    print(f"hashed={pcrs(hashed)} signed={pcrs(signed)}")
except struct.error:
    print("unreadable")
EOF
}

# check_sealed_pcrs NAME: the host key is bound to the signed PCR 11 policy and, on a Secure Boot
# image (--secure-boot), to PCR 7's value too (modules/vars/golconda-var-run)
check_sealed_pcrs() {
  WANT="hashed=- signed=11"
  if [ "$SECURE_BOOT" = 1 ]; then
    WANT="hashed=7 signed=11"
  fi
  PCRS=$(cred_pcrs "$HOSTKEY_CRED")
  echo "sshd-hostkey.key bound to: $PCRS (want $WANT)"
  RC=0
  [ "$PCRS" = "$WANT" ] || RC=1
  verdict "$1 ($WANT)" $RC
}

# reseal_vars NAME [--without-pcr7]: golconda-var-run --reseal seals every credential of the
# store again, as the db rotation procedure does (docs/design/bootloader.md): with the image's
# policy, or with the signed PCR 11 policy only. The host key credential gets new bytes, so
# SEALED_HASH follows it; check_unsealed then shows that the reseal kept the key
reseal_vars() {
  NAME=$1
  shift
  echo ""
  echo "=== golconda-var-run --reseal $* ==="
  RC=0
  OUT=$(guest /usr/lib/golconda/golconda-var-run --reseal "$@" 2>&1) || RC=1
  echo "$OUT"
  echo "$OUT" | grep -qx "resealed sshd-hostkey.key" || RC=1
  PCRS=$(cred_pcrs "$HOSTKEY_CRED")
  WANT="hashed=7 signed=11"
  if [ "${1:-}" = --without-pcr7 ]; then
    WANT="hashed=- signed=11"
  fi
  echo "sshd-hostkey.key bound to: $PCRS"
  [ "$PCRS" = "$WANT" ] || RC=1
  SEALED_HASH=$(guest_hash "$HOSTKEY_CRED")
  verdict "$NAME (every credential sealed again, the host key with $WANT)" $RC
}

# check_dm_usr NAME: /usr is the dm-verity device "usr". The host's udev has lvm2's dm rules
# (/base), so /dev/mapper/usr exists and dev-mapper-usr.device, which usr.mount requires, is active
check_dm_usr() {
  echo ""
  echo "=== $1: /dev/mapper/usr ==="
  RC=0
  S=$(guest "systemctl is-active dev-mapper-usr.device; ls /dev/mapper; test -b /dev/mapper/usr && echo block" 2>&1) || true
  echo "$S"
  [ "$(echo "$S" | head -1)" = active ] || RC=1
  echo "$S" | grep -qx block || RC=1
  verdict "$1 (dev-mapper-usr.device active, /dev/mapper/usr a block device)" $RC
}

# test_loader LABEL COUNTED: on a counted boot (COUNTED=1) golconda-loader-update.service ran
# after bless-boot, on a blessed one (0) it did not; the ESP's two copies of systemd-boot are
# /usr's signed file, the loader.conf in effect is /usr's and enrols nothing, and with Secure Boot
# the ESP holds no enrolment files
test_loader() {
  echo ""
  echo "=== boot loader ($1) ==="
  LU=""
  if [ "$2" = 1 ]; then
    # it runs after systemd-bless-boot.service, which waits for the health units (the network
    # one waits up to 60 s)
    wait_for 120 guest_active golconda-loader-update.service
    LU=$(guest systemctl is-active golconda-loader-update.service 2>/dev/null) || true
    guest journalctl -b -u golconda-loader-update.service -o cat --no-pager 2>&1 || true
    RC=0; [ "$LU" = active ] || RC=1
    verdict "loader-update-ran (golconda-loader-update.service after bless-boot: $LU)" $RC
  else
    LU=$(guest systemctl is-active golconda-loader-update.service 2>/dev/null) || true
    RC=0; [ "$LU" != active ] || RC=1
    verdict "loader-update-not-run (a blessed entry has no counter: $LU)" $RC
  fi

  USR=$(guest_hash "$USR_LOADER")
  PRI=$(guest_hash "$ESP_PRIMARY")
  REM=$(guest_hash "$ESP_REMOVABLE")
  echo "$USR_LOADER: $USR"
  echo "$ESP_PRIMARY: $PRI"
  echo "$ESP_REMOVABLE: $REM"
  RC=0
  { [ -n "$USR" ] && [ "$USR" = "$PRI" ] && [ "$USR" = "$REM" ]; } || RC=1
  verdict "loader-matches-usr (both ESP copies are the signed loader in /usr)" $RC

  # bootctl reads loader.conf where systemd-boot does, at the ESP's root
  CONF_LINE=$(guest bootctl status --no-pager 2>&1 | grep "config:") || true
  echo "$CONF_LINE"
  guest cat /boot/loader/loader.conf 2>&1 || true
  RC=0
  echo "$CONF_LINE" | grep -q "/loader/loader.conf$" || RC=1
  [ "$(guest_hash /boot/loader/loader.conf)" = "$(guest_hash /usr/lib/golconda/loader.conf)" ] || RC=1
  verdict "loader-conf-in-effect (ESP loader/loader.conf = /usr/lib/golconda/loader.conf)" $RC

  # the enrolment is armed on the first disk's ESP only: /usr's loader.conf, which
  # golconda-loader-update puts on the ESP, enrols nothing, and once Secure Boot is on the
  # enrolment files are gone (docs/design/bootloader.md, Enrolment)
  RC=0
  guest cat /boot/loader/loader.conf 2>/dev/null | grep -qx 'secure-boot-enroll off' || RC=1
  verdict "enrol-disarmed (the loader.conf in effect says secure-boot-enroll off)" $RC
  if [ "$SECURE_BOOT" = 1 ]; then
    KA=$(guest '[ -e /boot/loader/keys/auto ] && echo present || echo absent' 2>&1) || true
    echo "loader/keys/auto: $KA"
    RC=0; [ "$KA" = absent ] || RC=1
    verdict "enrol-keys-removed (Secure Boot is on: loader/keys/auto is gone from the ESP)" $RC
  fi

  # nothing enables it: only systemd's preset did, and 00-golconda.preset turns that off
  BA=$(guest systemctl show -P ActiveState systemd-boot-update.service 2>&1) || true
  BT=$(guest systemctl show -P InactiveExitTimestampMonotonic systemd-boot-update.service 2>&1) || true
  BU="$BA, left inactive at $BT"
  RC=0; [ "$BA" = inactive ] && [ "$BT" = 0 ] || RC=1
  verdict "boot-update-off (systemd-boot-update.service never started: $BU)" $RC
}

# test_release_index: the release directory a server publishes is the one docs/design/releases.md
# states, signed by the release key the running image trusts: golconda release check
test_release_index() {
  echo ""
  echo "=== golconda release check $NEXT_RELEASE ==="
  RC=0
  "$GOLCONDA" release check "$NEXT_RELEASE" --keys "$KEYS_DIR" || RC=1
  verdict "release-index (golconda release check: 4 lines in order, digests, UUIDs, signature)" $RC
}

# --- /imds (docs/features/provisioning.md) ---
IMDS_UNIT=systemd-imds-import.service

# check_imds_off: without a cloud in DMI, the generator pulls nothing in: neither the early network
# unit (which only the generator pulls) nor the import it hangs off ever left inactive.
check_imds_off() {
  echo ""
  echo "=== /imds without a cloud ==="
  RC=0
  for u in systemd-imds-early-network.service "$IMDS_UNIT"; do
    A=$(guest systemctl is-active "$u" 2>/dev/null) || true
    T=$(guest systemctl show -P InactiveExitTimestampMonotonic "$u" 2>/dev/null) || true
    echo "$u: ${A:-no answer}, left inactive at ${T:-no answer}"
    { [ "$A" = inactive ] && [ "$T" = 0 ]; } || RC=1
  done
  verdict "imds-import-inactive (no cloud in DMI: the early network unit and $IMDS_UNIT never started)" $RC
}

# wait_imds_import: the import the generator pulled in runs before sysinit.target, so it has ended
# by the first login; wait a little anyway. Never start it here, so a missed detection cannot pass.
# Sets IMDS_STATE.
imds_import_ended() {
  IMDS_STATE=$(guest systemctl is-active "$IMDS_UNIT" 2>/dev/null) || true
  case $IMDS_STATE in active | failed) ;; *) return 1 ;; esac
}
wait_imds_import() {
  wait_for 60 imds_import_ended
  guest journalctl -b -u "$IMDS_UNIT" -u systemd-firstboot.service -o cat --no-pager 2>&1 || true
}

# check_imds_hostname: the import ran and wrote firstboot.hostname, and systemd-firstboot set it
check_imds_hostname() {
  echo ""
  echo "=== /imds: host name ==="
  HN=$(guest hostname 2>&1) || true
  EH=$(guest cat /etc/hostname 2>&1) || true
  echo "$IMDS_UNIT: ${IMDS_STATE:-no answer}; hostname: $HN; /etc/hostname: $EH"
  RC=0; { [ "$IMDS_STATE" = active ] && [ "$HN" = imds-test ] && [ "$EH" = imds-test ]; } || RC=1
  verdict "imds-hostname (the generator pulled systemd's import in; hostname and /etc/hostname are imds-test)" $RC
}

# check_imds_layout: the guest found the endpoint as on Hetzner, by hwdb and the image's own data:
# it holds no imds.* credential, it asked for the host name and the user data at Hetzner's paths,
# and the server answered no request with 404 (systemd 262's 40-imds.hwdb asks for
# /hetzner/v1/metadata/public-keys/0 and /hetzner/v1/metadata/userdata, which Hetzner has not)
check_imds_layout() {
  echo ""
  echo "=== /imds: Hetzner's endpoint, found by hwdb ==="
  echo "requests:"
  grep '"GET ' "$IMDS_LOG" || true
  RC=0
  # imdsd's ImportCredential=imds.* reads the system credentials and the credstores; with none
  # passed (no SMBIOS credential in this mode), systemd-creds says so and exits 1
  CREDS=$(guest systemd-creds --system list --no-legend --no-pager 2>&1) || true
  echo "system credentials: $CREDS"
  STORES=$(guest 'ls /etc/credstore /run/credstore /usr/lib/credstore /etc/credstore.encrypted /run/credstore.encrypted /usr/lib/credstore.encrypted 2>/dev/null') || true
  IMDS_CREDS=$(printf '%s\n%s\n' "$CREDS" "$STORES" | grep '^imds[.]') || true
  echo "imds.* credentials: ${IMDS_CREDS:-none}"
  [ -z "$IMDS_CREDS" ] || RC=1
  grep -q '"GET /hetzner/v1/metadata/hostname HTTP/[0-9.]*" 200' "$IMDS_LOG" || RC=1
  grep -q '"GET /hetzner/v1/userdata HTTP/[0-9.]*" 200' "$IMDS_LOG" || RC=1
  if grep '"GET [^"]*" 404' "$IMDS_LOG"; then RC=1; fi
  verdict "imds-hetzner-layout (no imds.* credential; GET /hetzner/v1/metadata/hostname and /hetzner/v1/userdata answered 200; no 404)" $RC
}

# check_imds_ssh_keys: both keys of Hetzner's JSON array /metadata/public-keys log in as root, from
# the 0600 authorized_keys that tmpfiles wrote from the ssh.authorized_keys.root credential
# (systemd's ssh-key-json key, a Golconda patch until systemd has it). The bad entry between them
# is skipped alone, with a warning; the user data's own key of that name is skipped too.
check_imds_ssh_keys() {
  echo ""
  echo "=== /imds: ssh keys ==="
  RC=0
  for k in imds-project imds-project2; do
    # shellcheck disable=SC2086
    if ssh $SSH_OPTS $NO_HOSTKEY_CHECK -o IdentitiesOnly=yes -i "$WORKDIR/ssh/$k" root@localhost true; then
      echo "$k: logs in"
    else
      echo "$k: refused"; RC=1
    fi
  done
  M=$(guest stat -c %a /root/.ssh/authorized_keys 2>&1) || true
  echo "/root/.ssh/authorized_keys mode: $M"
  [ "$M" = 600 ] || RC=1
  # the bad entry between them is skipped alone, with a warning
  if guest grep -F 'bad' /root/.ssh/authorized_keys; then RC=1; fi
  guest journalctl -b -u "$IMDS_UNIT" -o cat --no-pager 2>&1 \
    | grep -F 'SSH key in IMDS JSON array contains control characters, skipping.' || RC=1
  verdict "imds-ssh-keys-json (both keys of the JSON array /metadata/public-keys log in, the bad entry is skipped with a warning; authorized_keys is 0600)" $RC

  RC=0
  # shellcheck disable=SC2086
  if ssh $SSH_OPTS $NO_HOSTKEY_CHECK -o IdentitiesOnly=yes -i "$WORKDIR/ssh/imds" root@localhost true; then
    echo "imds (the user data's key): logs in"; RC=1
  fi
  guest journalctl -b -u "$IMDS_UNIT" -o cat --no-pager 2>&1 \
    | grep -F "Skipping importing of credential 'ssh.authorized_keys.root'" || RC=1
  verdict "imds-ssh-key-precedence (the import skips the user data's ssh.authorized_keys.root, and its key does not log in)" $RC
}

# check_imds_userdata_credential: the user data's credentials arrive in /run/credstore, and a
# reader that starts after the import takes one: tmpfiles writes login.motd to /etc/motd.d
check_imds_userdata_credential() {
  echo ""
  echo "=== /imds: user data credentials ==="
  RC=0
  V=$(guest cat /run/credstore/imds-canary 2>&1) || true
  MOTD=$(guest cat /etc/motd.d/50-provision.conf 2>&1) || true
  echo "/run/credstore/imds-canary: $V"
  echo "/etc/motd.d/50-provision.conf: $MOTD"
  [ "$V" = canary ] || RC=1
  [ "$MOTD" = "imds motd" ] || RC=1
  verdict "imds-userdata-credential (imds-canary in /run/credstore; tmpfiles wrote login.motd)" $RC
}

# check_imds_ipv6: the user data's network.network.* credential takes effect in the boot that
# imported it: networkd configures the link with that file, and the link has its static global
# IPv6 address. QEMU's router advertisements name fec0::/64 only, so no other route gives it.
check_imds_ipv6() {
  echo ""
  echo "=== /imds: IPv6 from a user data .network credential ==="
  RC=0
  LINKS=$(guest networkctl list --no-legend --no-pager 2>/dev/null | awk '$3 == "ether" { print $2 }') || true
  [ -n "$LINKS" ] || RC=1
  for l in $LINKS; do
    LS=$(guest networkctl status --no-pager "$l" 2>&1) || true
    echo "$LS" | grep -E 'Network File|Address|Gateway' || true
    echo "$LS" | grep -q "Network File: /run/systemd/network/$IMDS_NET_CRED.network" || RC=1
    echo "$LS" | grep -qw "$IMDS_IPV6" || RC=1
  done
  if [ "$RC" != 0 ]; then
    guest ls /run/credstore /run/systemd/network 2>&1 || true
    guest journalctl -b -u systemd-networkd.service -o cat --no-pager 2>&1 | tail -20 || true
  fi
  verdict "imds-ipv6 (the link uses /run/systemd/network/$IMDS_NET_CRED.network from the user data, and has $IMDS_IPV6)" $RC
}

# check_imds_locked: with the user data's .network file on the link, which replaces
# 85-imds-early.network and its lock, only imdsd reaches the endpoint: systemd-pull, a root process without imdsd's firewall mark, gets no answer (the
# prohibit route) and the server sees no request from it, while `systemd-imds --cache=no` (through
# imdsd) makes the server answer again
check_imds_locked() {
  echo ""
  echo "=== /imds: the endpoint stays locked ==="
  RC=0
  URL=http://$IMDS_ADDR/hetzner/v1/metadata/hostname
  N0=$(grep -c '"GET /hetzner/v1/metadata/hostname ' "$IMDS_LOG") || N0=0
  P=$(guest "/usr/lib/systemd/systemd-pull raw --direct --verify=no $URL /run/imds-probe 2>&1; echo rc=\$?; rm -f /run/imds-probe") || true
  N1=$(grep -c '"GET /hetzner/v1/metadata/hostname ' "$IMDS_LOG") || N1=0
  H=$(guest /usr/lib/systemd/systemd-imds --cache=no -K hostname 2>&1) || true
  N2=$(grep -c '"GET /hetzner/v1/metadata/hostname ' "$IMDS_LOG") || N2=0
  echo "systemd-pull: $P"
  echo "systemd-imds -K hostname: $H"
  echo "GET .../hostname at the server: $N0 before, $N1 after systemd-pull, $N2 after systemd-imds"
  echo "$P" | grep -q '^rc=0$' && RC=1
  [ "$N1" = "$N0" ] || RC=1
  [ "$N2" -gt "$N1" ] || RC=1
  echo "$H" | grep -q imds-test || RC=1
  verdict "imds-endpoint-locked (with the user data's .network file, systemd-pull cannot reach $IMDS_ADDR; imdsd can)" $RC
}

# IMDS_LOCKED: every IMDS_ADDRESS_IPV4 and IMDS_ADDRESS_IPV6 of systemd 262.1's 40-imds.hwdb. QEMU's
# user network serves none of the IPv6 ones, and only 169.254.169.254 here, but the lock is a
# routing decision, taken before any server answers.
IMDS_LOCKED="169.254.169.254 169.254.42.42 100.100.100.200 fd00:ec2::254 fd00:c1::a9fe:a9fe fd00:42::42"

# check_imds_lock_endpoints: a root process that is not imdsd gets EACCES at connect() from the
# prohibit rule on lo (10-golconda-imds-lock.network) for every endpoint hwdb names, IPv6 too; a
# missing rule gives another error. The rule is on lo, so this also holds without a cloud in DMI.
check_imds_lock_endpoints() {
  echo ""
  echo "=== /imds: the lock covers every endpoint of 40-imds.hwdb, IPv6 too ==="
  RC=0
  for a in $IMDS_LOCKED; do
    E=$(guest "/usr/bin/ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=3 -p 22 $a true 2>&1") || true
    echo "$a: $E"
    echo "$E" | grep -q "port 22: Permission denied" || RC=1
  done
  # networkd took the file without a warning or an error about lo
  NL=$(guest journalctl -b -p warning -u systemd-networkd.service -o cat --no-pager 2>&1 | grep "lo:") || NL=""
  echo "networkd warnings about lo: ${NL:-none}"
  [ -z "$NL" ] || RC=1
  verdict "imds-lock-endpoints (a process that is not imdsd is refused with EACCES at every address of IMDS_LOCKED, IPv4 and IPv6)" $RC
}

# check_imds_ordering: the import is ordered after network-online.target and before sysinit.target
# and tmpfiles; systemd breaks an ordering cycle by dropping a job, so the journal must have none
check_imds_ordering() {
  N=$(guest journalctl -b -o cat --no-pager 2>/dev/null | grep -ci "ordering cycle") || N=0
  echo "ordering cycles in the journal: $N"
  RC=0; [ "$N" = 0 ] || RC=1
  verdict "imds-no-ordering-cycle (the import before sysinit.target)" $RC
}

# check_imds_dhcp_hostname: QEMU's DHCP server offers dhcp-test, and /imds's networkd drop-ins
# keep the lease from setting it: the lease holds the name, and after a renewal the host name is
# still IMDS's
check_imds_dhcp_hostname() {
  echo ""
  echo "=== /imds: the DHCP host name ==="
  # the lease's host name is in networkd's JSON (Interfaces[].DHCPv4Client.Lease.Hostname)
  J=$(guest networkctl status --json=short --no-pager 2>/dev/null) || true
  LEASE_HN=$(echo "$J" | grep -o '"Hostname":"[^"]*"' | sort -u) || true
  LINKS=$(guest networkctl list --no-legend --no-pager 2>/dev/null | awk '$3 == "ether" { print $2 }') || true
  # the drop-in /imds adds to 85-imds-early.network, the file systemd-imdsd writes on a cloud;
  # the link may have moved on to the user data's .network file (check_imds_ipv6), which sets
  # UseHostname=no itself
  EARLY=$(guest networkctl cat --no-pager 85-imds-early.network 2>&1) || true
  echo "ether links: ${LINKS:-none}; lease host names: ${LEASE_HN:-none}"
  echo "85-imds-early.network and its drop-ins:"
  echo "$EARLY" | grep -E '^# /|UseHostname' || true
  RC=0
  echo "$LEASE_HN" | grep -qx '"Hostname":"dhcp-test"' || RC=1
  echo "$EARLY" | grep -q '^# /usr/lib/systemd/network/85-imds-early.network.d/golconda-imds.conf$' || RC=1
  [ -n "$LINKS" ] || RC=1
  for l in $LINKS; do
    guest networkctl renew "$l" 2>&1 || RC=1
  done
  sleep 3
  HN=$(guest hostname 2>&1) || true
  echo "hostname after the renewal: $HN"
  [ "$HN" = imds-test ] || RC=1
  verdict "imds-dhcp-hostname (the lease offers dhcp-test, /imds's UseHostname=no drop-in reaches 85-imds-early.network, and after a renewal the host name is still imds-test)" $RC
}
