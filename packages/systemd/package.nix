# systemd: init system, service manager, and core system components for Golconda.
# A farm package: compiled-in paths are /usr/lib/systemd/..., served by the symlink farm.
{
  package,
  pkgs,
  buildPkgs,
}:
let
  deps = [
    pkgs.util-linux # libmount, libblkid, libuuid, libfdisk
    pkgs.libcap
    pkgs.libseccomp
    pkgs.openssl
    pkgs.p11-kit
    pkgs.tpm2-tss
    pkgs.cryptsetup # libcryptsetup
    pkgs.linux-pam
    pkgs.libxcrypt
    pkgs.zstd
    pkgs.lz4
    pkgs.xz
    pkgs.zlib
    pkgs.bzip2
    pkgs.curl
    pkgs.libarchive
    pkgs.pcre2
    pkgs.acl
    pkgs.attr
  ];
in
package {
  name = "systemd";
  uses = [ "meson" ];
  prefix = "/usr";

  # Hardening disabled: the EFI stub/boot code cannot use hardened flags (no libc, no stack
  # protector runtime). cc.hardening = false applies to the whole build. Trade-off documented:
  # EFI code is signed later by the image builder.
  cc.hardening = false;

  meson.defs = {
    # === Build mode ===
    mode = "release";
    split-bin = "false"; # no /sbin, everything in /usr/bin

    # === Disabled features (not in Golconda) ===
    ukify = "disabled"; # ukify is a Golconda build-time package only, not in the image
    kernel-install = false; # no kernel install hooks, image builder handles this
    kmod = "disabled"; # round 1 has no modules (monolithic kernel)
    audit = "disabled";
    selinux = "disabled";
    apparmor = "disabled";
    libfido2 = "disabled"; # FIDO2 keys handled client-side
    gcrypt = "disabled"; # OpenSSL only
    gnutls = "disabled"; # OpenSSL only
    microhttpd = "disabled"; # no journal-over-http
    elfutils = "disabled"; # no coredump backtrace symbolization
    bpf-framework = "disabled"; # no BPF
    libidn2 = "disabled"; # no IDN
    polkit = "disabled"; # run0 not in v1, root over ssh

    # === Enabled features ===
    pam = "enabled";
    p11kit = "enabled"; # PKCS#11 for TPM keys
    tpm2 = "enabled";
    libcryptsetup = "enabled";
    libcryptsetup-plugins = "disabled"; # no LUKS2 external token handlers
    openssl = "enabled";
    seccomp = "enabled";

    # === Components ===
    importd = "enabled"; # sysupdate needs importd
    sysupdate = "enabled";
    homed = "disabled";
    machined = false; # boolean in v262
    portabled = false; # boolean in v262
    localed = false; # boolean in v262
    vconsole = false; # boolean in v262
    hwdb = true;
    coredump = true;
    pstore = true;
    oomd = true;
    networkd = true;
    resolve = true;
    timesyncd = true;
    firstboot = true;
    repart = "enabled";
    sysusers = true;
    tmpfiles = true;

    # === Bootloader/EFI ===
    bootloader = "enabled";
    efi = true;
    sbat-distro = "golconda";
    sbat-distro-summary = "Golconda";
    sbat-distro-pkgname = "systemd";
    sbat-distro-url = "https://code.in.a.flawed.cloud/yolobox/golconda";

    # === Misc ===
    hibernate = false;
    man = "disabled";
    html = "disabled";
    translations = false;
    tests = "false";
    install-tests = false;
    dns-servers = "";
    ntp-servers = "";
    fallback-hostname = "golconda";
    create-log-dirs = false;

    # === SSH drop-in ===
    # Install the 20-systemd-userdb.conf drop-in for sshd: enables nss-systemd for user lookup.
    # Golconda has no userdb daemon in v1, but the drop-in is harmless and enables future use.
    sshdconfdir = "/etc/ssh/sshd_config.d";

    # === util-linux libraries ===
    fdisk = "enabled"; # for systemd-repart
    blkid = "enabled"; # for block device identification
    libmount = "enabled"; # for systemd-creds, systemd-mount, systemd-cryptsetup

    # === Dependencies ===
    libcurl = "enabled"; # for importd
    libarchive = "enabled"; # for importd (tar/cpio extraction)
    zlib = "enabled";
    bzip2 = "enabled";
    xz = "enabled";
    lz4 = "enabled";
    zstd = "enabled";
    pcre2 = "enabled"; # journalctl --grep
    acl = "enabled";

    # === Explicitly disabled dbus/glib (test-only) ===
    dbus = "disabled";
    glib = "disabled";

    # === Path configuration ===
    sysconfdir = "/etc";
  };

  # PYTHONPATH for meson's python3 module checks (jinja2, pyelftools)
  # The builder doesn't automatically propagate Python site-packages yet.
  env.PYTHONPATH = builtins.concatStringsSep ":" [
    "${buildPkgs.python-jinja2}/lib/python3.14/site-packages"
    "${buildPkgs.python-markupsafe}/lib/python3.14/site-packages"
    "${buildPkgs.python-pyelftools}/lib/python3.14/site-packages"
  ];

  buildDependencies = [
    buildPkgs.gperf
    buildPkgs.cpython
    buildPkgs.python-jinja2
    buildPkgs.python-pyelftools
  ];

  dependencies = deps;
  # systemd 262 dlopen()s most of these by soname (.note.dlopen), from libsystemd-shared: ld.so
  # looks in the caller's RUNPATH (Golconda has no ld.so.cache), so their lib dirs go there.
  # finish's dlopen-check holds every binary to it
  cc.ldflags = map (d: "-Wl,-rpath,${d}/lib") deps;

  # Override install to handle /etc and /var: meson installs them but finish rejects $out/etc.
  # These are sample configuration files; the image's tmpfiles C copies them.
  phases.replace."meson.install" = {
    name = "install";
    run = ''
      let destdir = $"($c.build)/dest"
      with-env {DESTDIR: $destdir} { x meson install --no-rebuild }
      # Copy /usr subtree to $out
      ^cp -r $"($destdir)/usr/." $c.out
      # systemd's vendor keyring holds image vendors' OpenPGP keys, and systemd-pull trusts it
      # beside every other keyring: the image ships its release key at that path instead
      # (lib/image/index.nix), so only that key signs an index the machine accepts
      rm -f $"($c.out)/lib/systemd/import-pubring.pgp"
      # Move /etc to share/factory/etc (sample configs, tmpfiles C copies them)
      # These become sources for tmpfiles C directive in the image.
      if ($"($destdir)/etc" | path exists) {
        mkdir $"($c.out)/share/factory"
        ^cp -r $"($destdir)/etc" $"($c.out)/share/factory/"
        note factory-etc "copied DESTDIR/etc to share/factory/etc"
        # Remove symlinks that point outside (to /usr or other system paths):
        # they're only valid at /etc at runtime, not in the package
        for f in (glob $"($c.out)/share/factory/etc/**/*") {
          if ($f | path type) == "symlink" {
            let target = (^readlink $f)
            # Any symlink containing /usr/ in the path or pointing outside etc/ via ..
            if (($target | str contains "usr/") or ($target | str contains "../xdg")) {
              rm $f
              note factory-etc $"removed external symlink ($f | path basename)"
            }
          }
        }
      }
      # Remove /var if present
      if ($"($destdir)/var" | path exists) {
        rm -rf $"($destdir)/var"
        note factory-etc "removed DESTDIR/var"
      }
      # .pc files: make prefix relative so pkg-config finds includes/libs
      for f in (files $"($c.out)/lib/pkgconfig/*.pc") {
        edit $f { str replace "prefix=/usr" "prefix=''${pcfiledir}/../.." }
      }
      # Remove dangling symlink: 99-environment.conf -> ../../../etc/environment
      # This points to /etc/environment which is a runtime config, not part of the package.
      # The image creates /etc/environment; environment.d reads it directly.
      let envlink = $"($c.out)/lib/environment.d/99-environment.conf"
      if ($envlink | path exists -n) {
        rm $envlink
        note factory-etc "removed dangling 99-environment.conf symlink"
      }
      # Remove systemd-update-helper: it's a bash script for rpm/deb scriptlets,
      # not needed for Golconda (immutable image). Its shebang pulls in bash.
      let helper = $"($c.out)/lib/systemd/systemd-update-helper"
      if ($helper | path exists) {
        rm $helper
        note factory-etc "removed systemd-update-helper (rpm/deb scriptlet, pulls bash)"
      }
    '';
  };

  # All executables installed in bin/: finish warns about any it finds that is not listed.
  bin = [
    # Core systemctl and friends
    "systemctl"
    "journalctl"
    "busctl"
    "loginctl"
    "hostnamectl"
    "networkctl"
    "resolvectl"
    "timedatectl"
    "udevadm"
    "bootctl"

    # Init and power control (symlinks to systemd)
    "init"
    "halt"
    "poweroff"
    "reboot"
    "shutdown"

    # systemd-* tools
    "systemd-ac-power"
    "systemd-analyze"
    "systemd-ask-password"
    "systemd-cat"
    "systemd-cgls"
    "systemd-cgtop"
    "systemd-confext"
    "systemd-creds"
    "systemd-cryptenroll"
    "systemd-cryptsetup"
    "systemd-delta"
    "systemd-detect-virt"
    "systemd-dissect"
    "systemd-escape"
    "systemd-firstboot"
    "systemd-hwdb"
    "systemd-id128"
    "systemd-inhibit"
    "systemd-machine-id-setup"
    "systemd-mount"
    "systemd-mstack"
    "systemd-mute-console"
    "systemd-notify"
    "systemd-path"
    "systemd-pty-forward"
    "systemd-repart"
    "systemd-resolve"
    "systemd-run"
    "systemd-socket-activate"
    "systemd-stdio-bridge"
    "systemd-sysext"
    "systemd-sysinstall"
    "systemd-sysusers"
    "systemd-tmpfiles"
    "systemd-tty-ask-password-agent"
    "systemd-umount"
    "systemd-vpick"

    # Other tools
    "coredumpctl"
    "importctl"
    "oomctl"
    "resolvconf"
    "run0"
    "storagectl"
    "userdbctl"
    "varlinkctl"

    # Mount helpers (called by systemd units)
    "mount.ddi"
    "mount.mstack"
    "mount.storage"
  ];

  # Tests: version check and ensure no bash in closure (Golconda has no bash)
  tests.run = false;
  tests.version = "--version";

  platforms.os = [ "linux" ];
}
