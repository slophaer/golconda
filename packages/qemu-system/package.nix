# QEMU's x86_64 system emulator for scripts/boot-test, and qemu-img for its disk overlay. A
# development tool, not part of an image. repkgs' own `qemu` is the user-mode emulators only (its
# cross tests), so this is a second build of the same source with another target list.
#
# Only what the boot test uses: the q35 machine with SMM (Secure Boot's variable store), KVM with
# TCG as the fallback, pflash, virtio-blk/net, the user network with hostfwd and guestfwd
# (libslirp), and the TPM (tpm-tis on swtpm's socket, the emulator backend). Every feature that is
# `auto` stays off (--without-default-features): no display (pixman, VNC, GTK, SDL), no audio, no
# guest agent, no seccomp, no vhost-user, no virtfs. The firmware QEMU ships for its own default
# boot (edk2-*.fd) is removed: the boot test brings its OVMF (packages/ovmf); the option ROMs
# (efi-virtio.rom, vgabios-stdvga.bin) and kvmvapic.bin stay, q35 loads them.
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
        # QEMU's own edk2 builds and their descriptors: one OVMF, packages/ovmf
        rm -rf ...(glob $"($c.out)/share/qemu/edk2-*") $"($c.out)/share/qemu/firmware"
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
