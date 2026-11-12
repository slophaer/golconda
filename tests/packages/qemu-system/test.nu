# qemu-system as scripts/boot-test runs it (scripts/boot-test-vm.sh, start_qemu): the q35 machine
# with SMM, KVM and TCG, the TPM on an emulator chardev (tpm-tis), virtio-blk and virtio-net on the
# user network, and qemu-img for the disk overlay. The sandbox has no /dev/kvm, so the machine
# starts on TCG, paused, and quits from the monitor: the devices are created and their option ROMs
# found (efi-virtio.rom, vgabios-stdvga.bin), but nothing runs. Its OVMF (share/qemu) is checked
# for what the boot test loads, at the end.
use checks.nu *
let bin = $"($env.pkg)/bin"
let qemu = $"($bin)/qemu-system-x86_64"
let t = $"($env.TMPDIR? | default /tmp)/qemu-system-test"
rm -rf $t
mkdir $t

let v = (^$qemu --version | lines | first)
assert $"version is the pin: ($v)" ($v | str contains "version 11.1.1")

# NAME is listed: a word of its own on a line ("q35   Standard PC", "  emulator   TPM emulator
# backend driver") or quoted (name "tpm-tis", bus System)
def listed [what: string, out: string, names: list<string>] {
  for n in $names {
    let word = ('(^|[ "])' + $n + '([ ",]|$)')
    assert $"($what) lists ($n)" ($out | lines | any {|l| $l =~ $word })
  }
}
# OPTION help, stdout and stderr (-tpmdev help prints to stderr)
def qhelp [option: string]: nothing -> string {
  let r = (^$qemu $option help | complete)
  $r.stdout + $r.stderr
}
listed "-machine help" (qhelp "-machine") [q35]
listed "-accel help" (qhelp "-accel") [kvm tcg]
listed "-device help" (qhelp "-device") [tpm-tis tpm-crb virtio-net-pci virtio-blk-pci virtio-rng-pci]
listed "-tpmdev help" (qhelp "-tpmdev") [emulator]
listed "-netdev help" (qhelp "-netdev") [user]

# the overlay as start_qemu makes it: qcow2 over a raw backing file
"" | save $"($t)/disk.raw"
^truncate -s 1M $"($t)/disk.raw"
let img = (^$"($bin)/qemu-img" create -q -f qcow2 -b $"($t)/disk.raw" -F raw $"($t)/disk.qcow2" 40G | complete)
assert $"qemu-img create: ($img.stderr)" ($img.exit_code == 0)
let info = (^$"($bin)/qemu-img" info $"($t)/disk.qcow2" | complete)
assert $"qemu-img info shows the backing file: ($info.stdout)" ($info.stdout | str contains "backing file format: raw")

# the machine of start_qemu without the firmware and the TPM socket: q35 with SMM, the disk on
# virtio, the user network with a host port and a guestfwd command, SMBIOS credentials
let run = ("quit\n" | ^$qemu -machine q35,smm=on,accel=tcg -cpu max -m 256M -S -display none
  -monitor stdio -serial null
  -drive $"file=($t)/disk.qcow2,format=qcow2,if=virtio"
  -smbios type=11,value=io.systemd.credential:system.hostname=qemu-test
  -netdev $"user,id=net0,net=169.254.169.0/24,hostfwd=tcp:127.0.0.1:10999-:22,guestfwd=tcp:169.254.169.2:8074-cmd:/bin/true"
  -device virtio-net-pci,netdev=net0
  -device virtio-rng-pci | complete)
assert $"the q35 machine starts and quits: ($run.stdout) ($run.stderr)" ($run.exit_code == 0)

rm -rf $t

# OVMF as scripts/boot-test loads it, QEMU's own edk2-stable202408 build from its release tarball
# (head of packages/qemu-system): the plain and the Secure Boot code image, and one empty variable
# store for both, which fill the 4 MB flash together. Each is a firmware volume ("_FVH"): the code
# ones a file system (EFI_FIRMWARE_FILE_SYSTEM2_GUID), the variable store the NV data volume
# (EFI_SYSTEM_NV_DATA_FV_GUID) holding an authenticated variable store (gEfiAuthenticatedVariableGuid),
# which Secure Boot's variables need. The GUIDs are as edk2 lays them out on disk (the first three
# fields little-endian). Whether the firmware enforces Secure Boot and measures into the TPM, only
# booting shows: the boot test's --secure-boot and --tpm.
let fw = $"($env.pkg)/share/qemu"
let kept = (ls $fw | get name | path basename | sort)
assert $"only the x86_64 firmware is kept: ($kept)" (($kept | where { $in =~ "^edk2-" }) == [edk2-i386-vars.fd edk2-licenses.txt edk2-x86_64-code.fd edk2-x86_64-secure-code.fd])
assert "no firmware descriptors (they name /usr/share/qemu)" (not ($"($fw)/firmware" | path exists))

const FS2 = 0x[78 e5 8c 8c 3d 8a 1c 4f 99 35 89 61 85 c3 2d d3]
const NV = 0x[8d 2b f1 ff 96 76 8b 4c a9 85 27 47 07 5b 4f 50]
const AUTH = 0x[78 2c f3 aa 7b 94 9a 43 a1 80 2e 14 4e c3 77 92]

let vars = (open --raw $"($fw)/edk2-i386-vars.fd" | into binary)
# the volume's length (offset 0x20, 64-bit little-endian): the variable store is one volume; the
# code image holds two (the compressed main volume first, then SEC with the reset vector)
let len = {|data| $data | bytes at 0x20..<0x28 | into int -e little }
assert "vars: a firmware volume" (($vars | bytes at 0x28..<0x2c) == ("_FVH" | into binary))
assert "vars: the NV data volume" (($vars | bytes at 0x10..<0x20) == $NV)
assert "vars: one volume, the whole file" ((do $len $vars) == ($vars | bytes length))
# the variable store header follows the 0x48-byte volume header
assert "vars: an authenticated variable store" (($vars | bytes at 0x48..<0x58) == $AUTH)
# empty: after the store header (28 bytes) the variable area is erased flash, 0xff
assert "vars: no variable is set" (($vars | bytes at 0x64..<0x1064 | bytes remove --all 0x[ff] | bytes length) == 0)

for name in [edk2-x86_64-code.fd edk2-x86_64-secure-code.fd] {
  let code = (open --raw $"($fw)/($name)" | into binary)
  let sizes = $"code ($code | bytes length), vars ($vars | bytes length)"
  assert $"($name): code and vars fill 4194304 bytes of flash: ($sizes)" ((($code | bytes length) + ($vars | bytes length)) == 4194304)
  assert $"($name): a firmware volume" (($code | bytes at 0x28..<0x2c) == ("_FVH" | into binary))
  assert $"($name): its file system GUID" (($code | bytes at 0x10..<0x20) == $FS2)
  assert $"($name): the main volume, then more" ((do $len $code) < ($code | bytes length))
}
done
