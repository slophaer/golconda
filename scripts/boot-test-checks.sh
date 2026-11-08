# shellcheck shell=sh
# Part of scripts/boot-test, sourced by it (no processes start when sourced).
# The checks: each is one function that every mode that needs it calls (docs/v1.md).
# shellcheck disable=SC2154 # the globals are set by scripts/boot-test and the other parts
# shellcheck disable=SC2034 # and read there

# vars CMD...: `golconda vars` against this guest, as an operator runs it: an ssh
# config names the guest boot-test, the store is $WORKDIR/vars, encrypted to a fresh age key
vars() {
  GOLCONDA_SSH="ssh -F $WORKDIR/ssh/config" "$GOLCONDA" vars "$@"
}

# push_admin_vars: the host CA signs the guest's host key; the host certificate and a revocation
# list naming cert-revoked are stored and pushed with golconda vars, and both must be sealed
push_admin_vars() {
  echo ""
  echo "=== admin vars: the host certificate and the revocation list, with golconda vars ==="
  cat > "$WORKDIR/ssh/config" <<EOF
Host boot-test
  HostName localhost
  Port $SSH_PORT
  User root
  IdentityFile $WORKDIR/ssh/user
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
  RC=0
  (
    cd "$WORKDIR" || exit 1
    vars pub boot-test sshd-hostkey key.pub > ssh/host.pub
    ssh-keygen -q -s ssh/host-ca -h -I boot-test -n localhost ssh/host.pub
    vars set boot-test sshd-host-cert cert < ssh/host-cert.pub
    echo "serial: 3" > ssh/krl.spec
    ssh-keygen -q -k -f ssh/krl -s "$REPO_DIR/tests/fixtures/snakeoil-user-ca.pub" ssh/krl.spec
    vars set boot-test sshd-revoked-keys krl < ssh/krl
    vars push -i age.key boot-test
  ) > "$WORKDIR/push.out" 2>&1 || RC=1
  cat "$WORKDIR/push.out"
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

# test_certs_after_update: the release that turned hostCertificate and revokedKeys on reads what
# was pushed: it presents the certificate, refuses the revoked user certificate, and a second
# revocation list, pushed while it runs, takes effect when sshd restarts (rotation)
test_certs_after_update() {
  echo ""
  echo "=== certificates after the update ==="
  RC=0
  echo "@cert-authority localhost,[localhost]:$SSH_PORT $(cat "$REPO_DIR/tests/fixtures/snakeoil-host-ca.pub")" \
    > "$WORKDIR/known_hosts_ca"
  # shellcheck disable=SC2086
  ssh $SSH_OPTS -o UserKnownHostsFile="$WORKDIR/known_hosts_ca" -o StrictHostKeyChecking=yes \
    -o HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com -o IdentitiesOnly=yes \
    -i "$WORKDIR/ssh/user" root@localhost true || RC=1
  verdict "host-cert-presented (the host CA vouches for the key; strict known_hosts)" $RC
  expect_login "cert-login-after-update" ok 0
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

# check_hwdb NAME: the hardware database is compiled into /usr (packages/hwdb, linked by /base), so
# nothing writes one to /etc and lookups answer: the IMDS entry for Hetzner Cloud's DMI vendor, and
# PCI and USB names (virtio-net's vendor, the root hub's). Run on the first release and on the one
# an update installed: each image carries its own.
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

# check_no_failed NAME: no unit has failed in the running boot
check_no_failed() {
  echo ""
  echo "=== systemctl --failed ($1) ==="
  FAILED=$(guest systemctl --failed --no-pager 2>&1) || true
  echo "$FAILED"
  RC=0; echo "$FAILED" | grep -q "^0 loaded units listed" || RC=1
  verdict "$1" $RC
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
    -i "$WORKDIR/ssh/user" root@localhost true || RC=1
  H=$(guest_hash "$HOSTKEY_CRED")
  [ -n "$H" ] && [ "$H" = "$SEALED_HASH" ] || RC=1
  A=$(guest systemctl is-active sshd.service 2>&1) || true
  [ "$A" = "active" ] || RC=1
  verdict "hostkey-unchanged ($1: the first boot's host key, credential not re-sealed, sshd $A)" $RC
}

# test_loader LABEL COUNTED: on a counted boot (COUNTED=1) golconda-loader-update.service ran
# after bless-boot, on a blessed one (0) it did not; the ESP's two copies of systemd-boot are
# /usr's signed file, and the loader.conf in effect is /usr's
test_loader() {
  echo ""
  echo "=== boot loader ($1) ==="
  LU=""
  if [ "$2" = 1 ]; then
    # it runs after systemd-bless-boot.service, which waits for the health units (the network
    # one waits up to 60 s)
    LW=0
    while [ "$LW" -lt 120 ] && qemu_running; do
      LU=$(guest systemctl is-active golconda-loader-update.service 2>/dev/null) || true
      [ "$LU" = active ] && break
      LW=$((LW + 2))
      sleep 2
    done
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

  CR=$(guest systemctl show -P ConditionResult systemd-boot-update.service 2>&1) || true
  RC=0; [ "$CR" = no ] || RC=1
  verdict "boot-update-off (systemd-boot-update.service ConditionResult=$CR)" $RC
}

# test_release_index: the release directory a server publishes, as docs/design/releases.md states
# it: four lines in the fixed order usr, verity, signature, UKI; the digest of each file; no line
# for the index itself.
test_release_index() {
  echo ""
  echo "=== release index ($NEXT_RELEASE/SHA256SUMS) ==="
  RC=0
  N=0
  while read -r digest name; do
    [ -n "$digest" ] || continue
    N=$((N + 1))
    # the release directory holds symlinks into the store, absolute or in $BOOT_TEST_STORE_ROOT
    got=$(sha256sum "$(real_path "$NEXT_RELEASE/$name")" 2>/dev/null | cut -c1-64) || got=""
    OK=ok
    [ "$got" = "$digest" ] || OK="digest mismatch"
    echo "$N: $name ($OK)"
    [ "$OK" = ok ] || RC=1
    case "$N:$name" in
      1:"$NEXT_NAME".usr.*.raw) ;;
      2:"$NEXT_NAME".usr-verity.*.raw) ;;
      3:"$NEXT_NAME".usr-verity-sig.raw) ;;
      4:"$NEXT_NAME".efi) ;;
      *) RC=1 ;;
    esac
  done < "$NEXT_RELEASE/SHA256SUMS"
  [ "$N" = 4 ] || RC=1
  verdict "release-index (4 lines: usr, verity, signature, UKI; digests match)" $RC
}

# test_etc_links: the links the first boot wrote under /etc/systemd/system named the old
# release's systemd store path. golconda-etc-links.service rewrote them in this boot's initrd,
# so no link may name a store path, and none may dangle (docs/design/updates.md).
test_etc_links() {
  echo ""
  echo "=== /etc/systemd/system links after the update ==="
  COUNTS=$(
    guest '
      n=0; s=0; d=0
      for f in /etc/systemd/system/* /etc/systemd/system/*/*; do
        [ -L "$f" ] || continue
        n=$((n + 1))
        case "$(readlink "$f")" in *nix/store*) s=$((s + 1)) ;; esac
        [ -e "$f" ] || d=$((d + 1))
      done
      echo "$n $s $d"'
  ) || COUNTS="0 0 0"
  echo "links, store-path targets, dangling: $COUNTS"
  # shellcheck disable=SC2086
  set -- $COUNTS
  RC=0
  [ "${1:-0}" -gt 0 ] || RC=1
  [ "${2:-1}" = 0 ] || RC=1
  [ "${3:-1}" = 0 ] || RC=1
  verdict "etc-links-stable ($1 links, $2 naming a store path, $3 dangling)" $RC
}
