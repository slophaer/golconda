# shellcheck shell=sh
# Part of scripts/boot-test, sourced by it (no processes start when sourced).
# The VM: Secure Boot keys, the TPM, the guest's credentials and keys, QEMU.
# shellcheck disable=SC2154 # the globals are set by scripts/boot-test and the other parts
# shellcheck disable=SC2034 # and read there

# real_path PATH: PATH with its symlinks followed; a target in /nix/store is looked up under
# $BOOT_TEST_STORE_ROOT, so a chroot store's outputs resolve on the host
real_path() {
  rp=$1
  while [ -L "$rp" ]; do
    rt=$(readlink "$rp")
    case $rt in
      /nix/store/*) rp=${BOOT_TEST_STORE_ROOT:-}$rt ;;
      /*) rp=$rt ;;
      *) rp=$(dirname "$rp")/$rt ;;
    esac
  done
  echo "$rp"
}

# --- host ports ---
# The one host port a run needs is the guest's ssh (hostfwd). Runs on one host must not take the
# same port, and two runs that both look for a free port must not find the same one: each claims a
# port with a flock on $PORT_LOCKS/PORT, held on a file descriptor until the run ends (the kernel
# drops it when the process dies, so no stale lock stays), and also checks that nothing listens.
PORT_LOCKS=${BOOT_TEST_PORT_LOCKS:-${XDG_RUNTIME_DIR:-/tmp}/boot-test-ports-$(id -u)}

# port_in_use PORT: true when 127.0.0.1:PORT is already bound
port_in_use() {
  python3 - "$1" <<'EOF'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(0)
sys.exit(1)
EOF
}

# claim_port FD PORT: take the lock for PORT on descriptor FD (kept to the end of the run); false
# when another run holds it or something listens on it
claim_port() {
  mkdir -p "$PORT_LOCKS"
  eval "exec $1>\"\$PORT_LOCKS/\$2\"" 2>/dev/null || return 1
  if flock -n "$1" && ! port_in_use "$2"; then
    return 0
  fi
  eval "exec $1>&-"
  return 1
}

# claim_ssh_port: SSH_PORT is BOOT_TEST_SSH_PORT (an error when it is taken), or the first free
# port from 10022 up
claim_ssh_port() {
  if [ -n "${BOOT_TEST_SSH_PORT:-}" ]; then
    SSH_PORT=$BOOT_TEST_SSH_PORT
    if ! claim_port 9 "$SSH_PORT"; then
      echo "Error: host port $SSH_PORT (BOOT_TEST_SSH_PORT) is in use or claimed by another boot-test run" >&2
      exit 1
    fi
  else
    SSH_PORT=10022
    while ! claim_port 9 "$SSH_PORT"; do
      SSH_PORT=$((SSH_PORT + 1))
      if [ "$SSH_PORT" -ge 10122 ]; then
        echo "Error: no free host port for ssh in 10022..10121" >&2
        exit 1
      fi
    done
  fi
  echo "ssh: 127.0.0.1:$SSH_PORT -> guest 22"
}

# --- enroll Secure Boot keys ---
enroll_keys() {
  DB_CERT="$KEYS_DIR/secureboot/db.crt"
  if [ ! -f "$DB_CERT" ]; then
    echo "Error: db.crt not found: $DB_CERT" >&2
    exit 1
  fi
  
  echo "Enrolling Secure Boot keys..."
  # virt-fw-vars 25.12 wants an owner GUID with every entry; one fixed GUID is fine
  # for a throwaway test key (the GUID names the entry, it does not verify anything)
  GUID=11111111-2222-3333-4444-555555555555
  # --rotate: step 1 of the rotation, the new db certificate beside the old one
  DB_NEXT=""
  if [ "$ROTATE" = 1 ]; then
    DB_NEXT="--add-db $GUID $NEXT_KEYS/secureboot/db.crt"
  fi
  # shellcheck disable=SC2086
  virt-fw-vars \
    --input "$VARS" \
    --output "$VARS.new" \
    --set-pk "$GUID" "$DB_CERT" \
    --add-kek "$GUID" "$DB_CERT" \
    --add-db "$GUID" "$DB_CERT" \
    $DB_NEXT \
    --secure-boot
  mv "$VARS.new" "$VARS"
  echo "Secure Boot keys enrolled"
}

# --- --auto-enrol: systemd-boot enrols the ESP's keys (docs/design/bootloader.md) ---
# The variable store is the firmware's empty template, in Setup Mode: enroll_keys does not run.
# systemd-boot finds loader/keys/auto on the ESP, writes db, KEK and PK (in that order; PK ends
# Setup Mode) and resets the machine; the next boot runs with Secure Boot on.

# efivar_holds NAME GUID SPEC...: the guest's EFI variable NAME-GUID (kept in the work directory)
# holds each SPEC +FILE and none of -FILE. FILE is a certificate (.crt PEM, .der DER), found as
# the DER of an EFI_SIGNATURE_LIST entry, or Microsoft's signed dbx update (.bin), whose signature
# lists must be the variable's content. A variable that does not exist holds nothing.
efivar_holds() {
  efi_v=$1
  efi_g=$2
  shift 2
  guest cat "/sys/firmware/efi/efivars/$efi_v-$efi_g" > "$WORKDIR/efivar-$efi_v" 2>/dev/null ||
    : > "$WORKDIR/efivar-$efi_v"
  python3 - "$WORKDIR/efivar-$efi_v" "$@" <<'EOF'
import ssl, struct, sys
# efivarfs puts the variable's 4 attribute bytes first
raw = open(sys.argv[1], "rb").read()
var = raw[4:]
ok = True
for spec in sys.argv[2:]:
    want, path = spec[0] == "+", spec[1:]
    data = open(path, "rb").read()
    if path.endswith(".crt"):
        data = ssl.PEM_cert_to_DER_cert(data.decode())
    if path.endswith(".bin"):
        # EFI_VARIABLE_AUTHENTICATION_2: EFI_TIME (16), then dwLength of the WIN_CERTIFICATE
        data = data[16 + struct.unpack_from("<I", data, 16)[0]:]
        found = len(data) > 0 and var == data
    else:
        found = len(data) > 0 and data in var
    print(("holds " if found else "lacks ") + path.rsplit("/", 1)[-1])
    ok = ok and found == want
sys.exit(0 if ok else 1)
EOF
}

# check_auto_enrol: systemd-boot enrolled the keys, and PK, KEK, db and dbx hold what the key set
# and, unless --no-microsoft-keys, Microsoft's objects (packages/secureboot-objects) say: KEK the
# key set's KEK.crt and Microsoft's KEK CA 2011 and 2023; db its db.crt and the Microsoft UEFI CA
# 2011 and 2023 and Option ROM UEFI CA 2023, never the two Windows CAs; dbx Microsoft's list. With
# --no-microsoft-keys none of Microsoft's, and no dbx. secure-boot-enabled is test_ssh's.
check_auto_enrol() {
  echo ""
  echo "=== Secure Boot keys enrolled by systemd-boot ==="
  RC=0
  # systemd-boot prints to the firmware console, which OVMF copies to the serial port
  grep -a 'Secure Boot keys' "$SERIAL_LOG" | tr -d '\033\r' | head -5 || true
  grep -aqF 'Custom Secure Boot keys successfully enrolled' "$SERIAL_LOG" || RC=1
  verdict "auto-enrolled (systemd-boot enrolled loader/keys/auto in Setup Mode and rebooted)" $RC
  GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c
  SECDB=d719b2cb-3d3a-4596-a3bc-dad00e67656f
  SB=$(real_path "$KEYS_DIR/secureboot")
  if ! MS=$(tools_outs "$REPO_DIR" secureboot-objects)/share/secureboot-objects; then
    verdict "secureboot-objects (packages.<system>.secureboot-objects builds)" 1
    return 1
  fi
  if [ "$MICROSOFT_KEYS" = 1 ]; then
    M=+
    WHOSE="the key set's and Microsoft's"
  else
    M=-
    WHOSE="only the key set's"
  fi
  RC=0
  efivar_holds PK "$GLOBAL" "+$SB/PK.crt" || RC=1
  verdict "pk-enrolled (the firmware's PK is the key set's secureboot/PK.crt)" $RC
  RC=0
  efivar_holds KEK "$GLOBAL" "+$SB/KEK.crt" "$M$MS/KEK/microsoft-kek-ca-2011.der" \
    "$M$MS/KEK/microsoft-kek-2k-ca-2023.der" || RC=1
  verdict "kek-enrolled (KEK holds $WHOSE: KEK.crt, Microsoft KEK CA 2011 and 2023)" $RC
  RC=0
  efivar_holds db "$SECDB" "+$SB/db.crt" "$M$MS/db/microsoft-uefi-ca-2011.der" \
    "$M$MS/db/microsoft-uefi-ca-2023.der" "$M$MS/db/microsoft-option-rom-uefi-ca-2023.der" \
    "-$MS/db/windows-production-pca-2011.der" "-$MS/db/windows-uefi-ca-2023.der" || RC=1
  verdict "db-enrolled (db holds $WHOSE: db.crt, Microsoft UEFI CA 2011, 2023, Option ROM UEFI CA 2023; no Windows CA)" $RC
  RC=0
  efivar_holds dbx "$SECDB" "$M$MS/dbx/DBXUpdate-amd64.bin" || RC=1
  verdict "dbx-enrolled (dbx is Microsoft's revocation list: $([ "$M" = + ] && echo yes || echo none))" $RC
}

# --- start TPM ---
start_tpm() {
  TPM_DIR="$WORKDIR/tpm"
  mkdir -p "$TPM_DIR"
  
  swtpm socket \
    --tpm2 \
    --tpmstate dir="$TPM_DIR" \
    --ctrl type=unixio,path="$TPM_DIR/swtpm-sock" \
    &
  SWTPM_PID=$!
  
  for _ in 1 2 3 4 5; do
    if [ -S "$TPM_DIR/swtpm-sock" ]; then
      break
    fi
    sleep 0.2
  done
  
  if [ ! -S "$TPM_DIR/swtpm-sock" ]; then
    echo "Error: swtpm socket not created" >&2
    exit 1
  fi
  
  echo "TPM started (pid $SWTPM_PID)"
}

# --- ESP credentials (--esp-creds) ---
# setup_esp_creds: copy the disk, make a key pair, write the credentials onto the copy's ESP
setup_esp_creds() {
  ssh-keygen -q -t ed25519 -N "" -C boot-test-esp -f "$SSH_DIR/user"
  cp --sparse=always "$DISK" "$WORKDIR/disk.raw"
  chmod u+w "$WORKDIR/disk.raw"
  DISK="$WORKDIR/disk.raw"
  if [ -n "${BOOT_TEST_ESP_NO_KEY:-}" ]; then
    "$SCRIPT_DIR/provision-esp" "$DISK" --hostname esp-test || exit 1
  else
    "$SCRIPT_DIR/provision-esp" "$DISK" --hostname esp-test --authorized-keys "$SSH_DIR/user.pub" || exit 1
  fi
  echo "Provisioned the ESP of $DISK; new key: $SSH_DIR/user"
}

# --- SSH test setup ---
setup_ssh_test() {
  SSH_DIR="$WORKDIR/ssh"
  mkdir -p "$SSH_DIR"
  
  if [ "$ESP_CREDS" = 1 ]; then
    setup_esp_creds
    return
  fi

  # Use the committed test SSH key from the repo
  TEST_KEY="$REPO_DIR/tests/fixtures/snakeoil-ssh"
  if [ ! -f "$TEST_KEY" ]; then
    echo "Error: test SSH key not found: $TEST_KEY" >&2
    exit 1
  fi
  
  # Copy the test key to the work directory
  cp "$TEST_KEY" "$SSH_DIR/user"
  chmod 600 "$SSH_DIR/user"
  
  echo "Using test SSH key: $TEST_KEY"
}

# setup_certs: user certificates from the test user CA (tests/fixtures/snakeoil-user-ca), which
# the test image trusts for the principal boot-test-admin: a good one, one for another principal,
# one the revocation list will name (by serial), and the harness's own (admin), which no list names
setup_certs() {
  cp "$REPO_DIR/tests/fixtures/snakeoil-user-ca" "$SSH_DIR/user-ca"
  chmod 600 "$SSH_DIR/user-ca"
  for c in "ok boot-test-admin 1" "wrong nobody 2" "revoked boot-test-admin 3" "admin boot-test-admin 4"; do
    # shellcheck disable=SC2086 # split the case into name, principal and serial
    set -- $c
    ssh-keygen -q -t ed25519 -N '' -C "boot-test-$1" -f "$SSH_DIR/cert-$1"
    ssh-keygen -q -s "$SSH_DIR/user-ca" -I "boot-test-$1" -n "$2" -z "$3" "$SSH_DIR/cert-$1.pub"
  done
  # --enrol: a plain bootstrap key that only the SMBIOS credential ssh.authorized_keys.root
  # carries (start_qemu); the pushed KRL does not name it
  if [ "$ENROL" = 1 ]; then
    ssh-keygen -q -t ed25519 -N '' -C boot-test-bootstrap -f "$SSH_DIR/bootstrap"
  fi
}

# --- run QEMU ---
start_qemu() {
  # a later QEMU run (--rotate) boots the same overlay again
  if [ ! -f "$OVERLAY" ]; then
    qemu-img create -q -f qcow2 -b "$DISK" -F raw "$OVERLAY" 40G
  fi

  # the --tpm, --next and --factory-reset runs reboot the guest in the same QEMU, and so does
  # systemd-boot after it enrols the keys (--auto-enrol)
  NO_REBOOT=-no-reboot
  if [ "$TPM" = 1 ] || [ -n "$NEXT" ] || [ "$FACTORY_RESET" = 1 ] || [ "$AUTO_ENROL" = 1 ]; then
    NO_REBOOT=""
  fi

  SMBIOS_HOSTNAME="-smbios type=11,value=io.systemd.credential:system.hostname=boot-test"
  if [ "$ESP_CREDS" = 1 ] || [ "$IMDS" = 1 ]; then
    SMBIOS_HOSTNAME=""
  fi
  # --enrol: the bootstrap key as a provisioning credential (docs/design/boot.md); base64, because
  # the key line has spaces
  SMBIOS_BOOTSTRAP=""
  if [ "$ENROL" = 1 ]; then
    SMBIOS_BOOTSTRAP="-smbios type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root=$(base64 -w0 "$SSH_DIR/bootstrap.pub")"
  fi
  # --imds: Hetzner by DMI, and nothing else: the guest takes the endpoint from hwdb and the
  # image, as on Hetzner. Its address, 169.254.169.254, must be on the guest's link (imdsd's route
  # to it has Scope=link), so QEMU's user network is GUEST_NET in every mode, and QEMU answers ARP
  # for the guestfwd address. QEMU's DHCP server offers a host name, which networkd must not apply.
  SMBIOS_IMDS=""
  NET_IMDS=""
  if [ "$IMDS" = 1 ]; then
    SMBIOS_IMDS="-smbios type=0,vendor=Hetzner"
    NET_IMDS=",hostname=dhcp-test,guestfwd=tcp:$IMDS_ADDR:80-cmd:$WORKDIR/serve-imds"
  fi

  # --next: the guest's connections to the image's update source, $UPDATE_ADDR:$HTTP_PORT, go to
  # this run's own server (boot-test-http.sh), whatever the host ports are
  NET_UPDATE=""
  if [ -n "$NEXT" ]; then
    NET_UPDATE=",guestfwd=tcp:$UPDATE_ADDR:$HTTP_PORT-cmd:$WORKDIR/serve-http"
  fi

  # --ssh-test: the CA store check's two HTTPS servers (boot-test-tls.sh)
  NET_TLS=""
  if [ "$SSH_TEST" = 1 ]; then
    NET_TLS=",guestfwd=tcp:$TLS_ADDR_ANCHOR:443-cmd:$WORKDIR/serve-tls-anchor,guestfwd=tcp:$TLS_ADDR_DISTRUSTED:443-cmd:$WORKDIR/serve-tls-distrusted"
  fi

  QEMU_ARGS="-machine q35,accel=kvm:tcg \
    -cpu max \
    -m 2G \
    -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
    -drive if=pflash,format=raw,file=$VARS \
    -drive file=$OVERLAY,format=qcow2,if=virtio \
    -serial file:$SERIAL_LOG \
    -display none \
    $NO_REBOOT \
    $SMBIOS_HOSTNAME \
    $SMBIOS_BOOTSTRAP \
    $SMBIOS_IMDS \
    -netdev user,id=net0,net=$GUEST_NET,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22$NET_UPDATE$NET_IMDS$NET_TLS \
    -device virtio-net-pci,netdev=net0"
  
  if [ "$TPM" = 1 ] || [ "$SECURE_BOOT" = 1 ]; then
    QEMU_ARGS="$QEMU_ARGS \
      -machine smm=on -global driver=cfi.pflash01,property=secure,value=on"
  fi
  if [ "$TPM" = 1 ]; then
    QEMU_ARGS="$QEMU_ARGS \
      -chardev socket,id=chrtpm,path=$WORKDIR/tpm/swtpm-sock \
      -tpmdev emulator,id=tpm0,chardev=chrtpm \
      -device tpm-tis,tpmdev=tpm0"
  fi
  
  echo "Starting QEMU (timeout ${TIMEOUT}s)..."
  : > "$SERIAL_LOG"
  # shellcheck disable=SC2086
  timeout "$TIMEOUT" qemu-system-x86_64 $QEMU_ARGS > "$QEMU_OUT" 2>&1 &
  QEMU_PID=$!
}

qemu_running() {
  kill -0 "$QEMU_PID" 2>/dev/null
}

stop_qemu() {
  if qemu_running; then
    kill "$QEMU_PID" 2>/dev/null || true
  fi
  wait "$QEMU_PID" 2>/dev/null || true
  echo "QEMU stopped"
}
