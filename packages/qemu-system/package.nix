# QEMU's x86_64 system emulator for scripts/boot-test, and qemu-img for its disk overlay. A
# development tool, not part of an image. repkgs' own `qemu` is the user-mode emulators only (its
# cross tests), so this is a second build of the same source with another target list.
#
# Only what the boot test uses: the q35 machine with SMM (Secure Boot's variable store), KVM with
# TCG as the fallback, pflash, virtio-blk/net, the user network with hostfwd and guestfwd
# (libslirp), and the TPM (tpm-tis on swtpm's socket, the emulator backend). Every feature that is
# `auto` stays off (--without-default-features): no display (pixman, VNC, GTK, SDL), no audio, no
# guest agent, no seccomp, no vhost-user, no virtfs. The option ROMs (efi-virtio.rom,
# vgabios-stdvga.bin) and kvmvapic.bin stay, q35 loads them.
#
# The boot test's firmware (OVMF) is the one QEMU's release tarball ships in pc-bios/, kept in
# share/qemu: edk2-x86_64-secure-code.fd (Secure Boot, SMM, TPM 2.0), edk2-x86_64-code.fd (the
# same without Secure Boot and SMM), and edk2-i386-vars.fd, the empty variable store for both
# (QEMU's descriptors pair the 32-bit name with the 64-bit code). The code images are 3.5 MB and the
# store 528 KB: together the 4 MB flash. The QEMU project builds them with edk2-stable202408
# (roms/edk2-build.config: OvmfPkgX64.dsc, TPM2_ENABLE, and for the secure one SECURE_BOOT_ENABLE and
# SMM_REQUIRE, no EFI shell) and checks the .bz2 blobs into the tarball; meson unpacks them at install.
# Trust: prebuilt by the QEMU project, inside the tarball that sources.toml pins by hash; not rebuilt
# here. The other edk2 images (32-bit, ARM, RISC-V, LoongArch, microvm) and the firmware descriptors
# are removed. Building edk2 from source (its BaseTools, nasm, iasl) is a later step.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "qemu-system";
  dependencies = [
    pkgs.glib
    pkgs.zlib
    pkgs.libslirp
  ];
  buildDependencies = [
    buildPkgs.cpython
    buildPkgs.ninja
    # meson unpacks the edk2 blobs with it when install_blobs is on (the default), and the
    # option ROMs are among the same blobs
    buildPkgs.bzip2
  ];
  phases = [
    {
      name = "configure";
      run = ''
        # the tooling venv group wants setuptools, wheel and pip to install qemu's own python/
        # package, which only the functional tests use (as repkgs' qemu)
        let deps = (open --raw pythondeps.toml | lines | where { $in !~ '^"(qemu|setuptools|wheel|pip)" =' })
        $deps | str join "\n" | save -f pythondeps.toml
        cd $c.build
        $env.PKG_CONFIG = "pkg-config"
        # --prefix paths are templates, get_relocated_path() rebases them on the binary
        (x (tool sh) $"($c.src)/configure" --prefix=/usr --disable-download --without-default-features
          --target-list=x86_64-softmmu --disable-user --enable-kvm --enable-slirp --enable-tpm
          --enable-tools --disable-docs --disable-werror $"--python=(which python3 | get 0.path)")
      '';
    }
    {
      name = "build";
      run = "x ninja -C $c.build $\"-j($c.njobs)\"";
    }
    {
      # through ninja: the meson that configured is qemu's vendored one, not ours
      name = "install";
      run = ''
        with-env {DESTDIR: $"($c.build)/dest"} { x ninja -C $c.build install }
        ^cp -r $"($c.build)/dest/usr/." $c.out
        # only the x86_64 firmware the boot test loads (see the head of this file), their licenses,
        # and no descriptors (they name /usr/share/qemu)
        let keep = [edk2-x86_64-secure-code.fd edk2-x86_64-code.fd edk2-i386-vars.fd edk2-licenses.txt]
        rm -rf ...(glob $"($c.out)/share/qemu/edk2-*" | where { ($in | path basename) not-in $keep }) $"($c.out)/share/qemu/firmware"
      '';
    }
  ];
  tests.run = false;
  bin = [
    "qemu-system-x86_64"
    "qemu-img"
  ];
  platforms.os = [ "linux" ];
}
