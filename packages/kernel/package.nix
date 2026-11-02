# Golconda's x86_64 kernel. The typed base and golconda.config are verified by repkgs' kbuild.
# nix/packages.nix appends the policy fragment and substitutes the IPE boot policy path.
# Use raw clang/lld for kernel code; host tools still use the configured host compiler.
{
  package,
  buildPkgs,
}:
let
  # Options are verified after olddefconfig resolves dependencies.
  baseConfig = {
    # ===== QEMU: virtio devices on PCI =====
    PCI = "y";
    VIRTIO = "y";
    VIRTIO_PCI = "y";
    VIRTIO_BLK = "y";
    VIRTIO_NET = "y";
    VIRTIO_CONSOLE = "y";
    BLOCK = "y";
    NET = "y";

    # ===== Serial console (qemu -nographic, console=ttyS0) =====
    TTY = "y";
    SERIAL_8250 = "y";
    SERIAL_8250_CONSOLE = "y";

    # ===== Boot an initramfs and run /init =====
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

    # ===== No modules =====
    MODULES = "n";

    # ===== The smoke test reads /proc/config.gz =====
    IKCONFIG = "y";
    IKCONFIG_PROC = "y";

    # ===== Unwinder: ORC (objtool/sorttable need pthreads; libunwind fixed in the glibc output) =====
    UNWINDER_ORC = "y";
    UNWINDER_FRAME_POINTER = "n";
  };
in
package {
  name = "linux-kernel";

  uses = [ "kbuild" ];

  kbuild.base = "defconfig";
  kbuild.config = baseConfig;
  # target auto-detected from platform in kbuild.nu
  kbuild.extraMake = [
    # Use raw clang/lld for kernel code (no jig hardening flags)
    "CC=clang"
    "LD=ld.lld"
    "AR=llvm-ar"
    "NM=llvm-nm"
    "STRIP=llvm-strip"
    "OBJCOPY=llvm-objcopy"
    "OBJDUMP=llvm-objdump"
    "READELF=llvm-readelf"
    # Use jig's cc for host tools: they need sysroot headers
    "HOSTCC=cc"
    "HOSTCXX=c++"
    "HOSTLD=ld.lld"
    # buildDependencies are tools on PATH, not include/library paths: point HOSTCC at the host
    # libraries (objtool: libelf; extract-cert: openssl; sorttable: libunwind)
    "HOSTCFLAGS=-I${buildPkgs.elfutils}/include -I${buildPkgs.openssl}/include"
    "HOSTLDFLAGS=-L${buildPkgs.elfutils}/lib -L${buildPkgs.openssl}/lib -L${buildPkgs.libunwind}/lib -Wl,-rpath,${buildPkgs.elfutils}/lib -Wl,-rpath,${buildPkgs.openssl}/lib -Wl,-rpath,${buildPkgs.libunwind}/lib"
    "HOSTAR=llvm-ar"
    # Reproducibility
    "KBUILD_BUILD_TIMESTAMP=@315532800"
    "KBUILD_BUILD_USER=golconda"
    "KBUILD_BUILD_HOST=build"
    "KBUILD_BUILD_VERSION=1"
  ];

  # Disable jig's hardening: the kernel sets its own
  cc.hardening = false;

  # Everything here runs or links on the build machine (kconfig, objtool, sorttable, extract-cert),
  # so a cross build needs it for the build platform: buildDependencies, not dependencies.
  # kconfig needs flex and bison; timeconst.h needs bc; oid_registry needs perl.
  # objtool needs elfutils headers/libs via pkg-config.
  # extract-cert needs openssl headers.
  # sorttable needs libunwind for pthread_exit at runtime.
  # These only affect HOSTCC (jig) via -isystem, which the kernel's own code ignores
  # (it uses raw clang via CC=clang).
  buildDependencies = [
    buildPkgs.flex
    buildPkgs.bison
    buildPkgs.bc
    buildPkgs.perl
    buildPkgs.elfutils
    buildPkgs.openssl
    buildPkgs.libunwind
  ];

  # No version test: kernel has no --version flag
  bin = [ ];
  tests.run = false;

  platforms = {
    os = [ "linux" ];
    cpu = [ "x86_64" ];
  };
}
