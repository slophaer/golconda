# virt-fw-vars as scripts/boot-test runs it (scripts/boot-test-vm.sh, enroll_keys; --rotate in
# boot-test-update.sh): Secure Boot keys written offline into a copy of OVMF's empty variable store
# (qemu-system's edk2-i386-vars.fd, inputs.nix). A certificate comes from virt-fw-vars itself (--enroll-generate,
# then --extract-certs); then the boot test's calls: PK, KEK and db from that certificate with one
# owner GUID and Secure Boot on, and the rotation: db replaced, the old certificate into dbx. The
# certificate is parsed by python-cryptography and the store written in edk2's format; --print
# reads each result back.
use checks.nu *
let vars = $"($env.pkg)/bin/virt-fw-vars"
let t = $"($env.TMPDIR? | default /tmp)/virt-firmware-test"
rm -rf $t
mkdir $t
cd $t
^cp $"($env.qemu)/share/qemu/edk2-i386-vars.fd" empty.fd
^chmod u+w empty.fd

def --wrapped fwvars [what: string, ...args: string]: nothing -> string {
  let r = (^$vars ...$args | complete)
  assert $"($what): ($r.stdout) ($r.stderr)" ($r.exit_code == 0)
  $r.stdout + $r.stderr
}

let empty = (fwvars "print the empty store" -i empty.fd --print)
assert $"the empty store has no PK: ($empty)" (not ($empty | str contains "PK"))

# two throwaway certificates, as the boot test has (its db key and the rotated one)
for cn in [old new] {
  mkdir $cn
  cd $cn
  fwvars $"generate ($cn)" -i ../empty.fd -o gen.fd --enroll-generate $"golconda-test-($cn)" --no-microsoft --microsoft-kek none
  fwvars $"extract ($cn)" -i gen.fd --extract-certs
  # PK-<owner GUID>-<CN without dashes>.pem
  let pem = (glob PK-*.pem | sort | where {|f| (open --raw $f | decode utf-8) =~ "BEGIN CERTIFICATE" })
  assert $"($cn): its certificate was extracted" (($pem | length) == 1)
  ^cp ($pem | first) ../($cn).pem
  cd ..
}

# VAR's entry in --print --verbose output: from its "name=VAR guid=..." line to the next name=
def entry [out: string, var: string]: nothing -> string {
  $out | split row "name=" | where { $in starts-with $"($var) " } | str join ""
}

const GUID = "11111111-2222-3333-4444-555555555555"
fwvars "enrol PK, KEK and db" --input empty.fd --output sb.fd --set-pk $GUID old.pem --add-kek $GUID old.pem --add-db $GUID old.pem --secure-boot
let sb = (fwvars "print the enrolled store" -i sb.fd --print --verbose)
for var in [PK KEK db] {
  assert $"($var) holds the certificate: ($sb)" ((entry $sb $var) | str contains "subject CN=golconda-test-old")
}
assert "Secure Boot is on" ((entry $sb SecureBootEnable) | is-not-empty)

fwvars "rotate db" --input sb.fd --output rotated.fd --delete db --add-db $GUID new.pem --add-dbx-cert $GUID old.pem
let rot = (fwvars "print the rotated store" -i rotated.fd --print --verbose)
let db = (entry $rot db)
assert $"db holds the new certificate alone: ($rot)" (($db | str contains "subject CN=golconda-test-new") and not ($db | str contains "golconda-test-old"))
assert $"dbx holds the old one: ($rot)" ((entry $rot dbx) | str contains "subject CN=golconda-test-old")
assert "PK is kept" ((entry $rot PK) | str contains "subject CN=golconda-test-old")
assert "the rotated store is as large as the template" ((ls rotated.fd | first | get size) == (ls empty.fd | first | get size))

cd /
rm -rf $t
done
