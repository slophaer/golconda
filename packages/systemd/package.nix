# systemd: init system, service manager, and core system components for Golconda.
# A farm package: compiled-in paths are /usr/lib/systemd/..., served by the symlink farm.
{
  package,
  pkgs,
  buildPkgs,
}:
let
  # systemd's built-in clock epoch (`time-epoch`): PID 1 and timesyncd never set the clock before
  # it, and PID 1 sets a clock more than 15 years past it back to it. Left unset, meson takes
  # SOURCE_DATE_EPOCH, 1980-01-01 in a reproducible build, so every boot reset the RTC's right time
  # to 1980 until timesyncd synced (DNSSEC and TLS failed meanwhile). It is the pin's date from
  # sources.toml, midnight UTC: a fixed instant in the source, so the build stays reproducible, no
  # earlier than the release the tarball is, and no later than any build of it; each bump of the pin
  # moves it, so the 15 years run from the pin. The first sync, and every later boot, uses the mtime
  # of /var/lib/systemd/timesync/clock when that is newer.
  pinDate = (builtins.fromTOML (builtins.readFile ./sources.toml)).pin.date;
  versionLib = import ../../lib/version.nix { };
  timeEpoch = versionLib.toEpoch "${builtins.replaceStrings [ "-" ] [ "" ] pinDate}.0";

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

  # hwdb: Hetzner Cloud's IMDS paths. 40-imds.hwdb names /hetzner/v1/metadata/public-keys/0 and
  # /hetzner/v1/metadata/userdata, which Hetzner answers with 404, so the import fails. The patch
  # is the commit prepared for systemd upstream (branch hwdb-imds-hetzner, `git format-patch -U1`,
  # as main's next entry differs from 262.1's); packages/hwdb compiles the fixed entry. Drop it
  # when systemd ships the fix.
  # imds: Hetzner lists the ssh keys only as a JSON array (/metadata/public-keys), and systemd-imds
  # reads one plain key. imds-ssh-key-json.patch adds the well-known key ssh-key-json, imported one
  # line per key into ssh.authorized_keys.root; hwdb-imds-hetzner-ssh-keys.patch names it in the
  # fixed Hetzner entry. Both are commits drafted for systemd upstream (branch imds-ssh-keys-json,
  # backported onto 262.1 after the patch above); drop them when systemd ships the key.
  patches = [
    ./hwdb-imds-hetzner.patch
    ./imds-ssh-key-json.patch
    ./hwdb-imds-hetzner-ssh-keys.patch
  ];

  # Hardening disabled: the EFI stub/boot code cannot use hardened flags (no libc, no stack
  # protector runtime). cc.hardening = false applies to the whole build. Trade-off documented:
  # EFI code is signed later by the image builder.
  cc.hardening = false;

  meson.defs = {
    # === Build mode ===
    mode = "release";
    time-epoch = timeEpoch;
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
    polkit = "disabled"; # no run0 yet, root over ssh
    # no systemd-sysext or systemd-confext: they overlay /usr and /etc with images from
    # /var/lib/extensions, /etc/extensions and the ESP, which an offline write can plant.
    # Software comes from modules at build time (docs/design/comparison.md)
    sysext = false;

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
    # cloud instance metadata: systemd-imdsd, systemd-imds, the generator and the units. /base
    # keeps the units off unless the configuration has /imds (modules/base/parts/imds.nix).
    # locked: the early network file adds a prohibit route to the endpoint, so only imdsd (with
    # its fwmark) reaches it, not every process on the machine (a user data with a secret in it,
    # an SSRF in a service). meson's default is unlocked.
    imds = "enabled";
    imds-network = "locked";
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
    # Golconda has no userdb daemon yet, but the drop-in is harmless and enables future use.
    sshdconfdir = "/etc/ssh/sshd_config.d";

    # === util-linux libraries ===
    fdisk = "enabled"; # for systemd-repart
    blkid = "enabled"; # for block device identification
    libmount = "enabled"; # for systemd-creds, systemd-mount, systemd-cryptsetup

    # === Dependencies ===
    libcurl = "enabled"; # for importd and imds
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

  # meson's python3 module checks import jinja2 and pyelftools: the builder puts the build
  # dependencies' site-packages on PYTHONPATH, with what they propagate (markupsafe)
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

  # meson installs below /usr, /etc and /var. The builder's staged install takes /usr as the
  # output and makes the .pc files relative; /etc holds sample configuration files, which become
  # share/factory/etc, the source of the image's tmpfiles C lines. /var is not shipped
  stagedRoots = {
    "/etc" = "share/factory/etc";
    "/var" = null;
  };
  phases.after."meson.install" = [
    {
      name = "factory-cleanup";
      run = ''
        # systemd's vendor keyring holds image vendors' OpenPGP keys, and systemd-pull trusts it
        # beside every other keyring: the image ships its release key at that path instead
        # (lib/image/index.nix), so only that key signs an index the machine accepts
        rm -f $"($c.out)/lib/systemd/import-pubring.pgp"
        # systemd-ssh-generator binds a second sshd, with sshd_config's defaults and an
        # AuthorizedKeysFile of its own, to AF_UNIX /run/ssh-unix-local/socket, to AF_VSOCK and
        # to any address an ssh.listen credential or systemd.ssh_listen= names. meson has no
        # option for it; Golconda's sshd.service (/services/sshd) is the one ssh server
        rm $"($c.out)/lib/systemd/system-generators/systemd-ssh-generator"
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
    }
  ];

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
