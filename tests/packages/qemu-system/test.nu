# qemu-system as scripts/boot-test runs it (scripts/boot-test-vm.sh, start_qemu): the q35 machine
# with SMM, KVM and TCG, the TPM on an emulator chardev (tpm-tis), virtio-blk and virtio-net on the
# user network, and qemu-img for the disk overlay. The sandbox has no /dev/kvm, so the machine
# starts on TCG, paused, and quits from the monitor: the devices are created and their option ROMs
# found (efi-virtio.rom, vgabios-stdvga.bin), but nothing runs.
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
done
