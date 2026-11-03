# The x86_64 base over defconfig. golconda.config adds the OS policy; kbuild.nu verifies both
# after olddefconfig resolves dependencies.
{
  # QEMU: virtio devices on PCI
  PCI = "y";
  VIRTIO = "y";
  VIRTIO_PCI = "y";
  VIRTIO_BLK = "y";
  VIRTIO_NET = "y";
  VIRTIO_CONSOLE = "y";
  BLOCK = "y";
  NET = "y";

  # Serial console (qemu -nographic, console=ttyS0)
  TTY = "y";
  SERIAL_8250 = "y";
  SERIAL_8250_CONSOLE = "y";

  # Boot an initramfs and run /init
  BLK_DEV_INITRD = "y";
  RD_GZIP = "y";
  BINFMT_ELF = "y";
  BINFMT_SCRIPT = "y";
  PROC_FS = "y";
  SYSFS = "y";
  TMPFS = "y";
  DEVTMPFS = "y";
  DEVTMPFS_MOUNT = "y";
  PRINTK = "y";

  # No modules: the kernel is monolithic, so the image needs no kmod
  MODULES = "n";

  # The smoke test reads /proc/config.gz
  IKCONFIG = "y";
  IKCONFIG_PROC = "y";

  # Full DWARF 5 in vmlinux, which install copies to the debug output (Linux 6.18 "Debug
  # information" choice; LLVM_IAS=1 meets its assembler condition). Not reduced, not split into
  # .dwo files. BTF stays off (golconda.config)
  DEBUG_KERNEL = "y";
  DEBUG_INFO = "y";
  DEBUG_INFO_DWARF5 = "y";
  DEBUG_INFO_REDUCED = "n";
  DEBUG_INFO_SPLIT = "n";

  # Unwinder: ORC (objtool and sorttable need pthreads; libunwind is fixed in the glibc output)
  UNWINDER_ORC = "y";
  UNWINDER_FRAME_POINTER = "n";
}
