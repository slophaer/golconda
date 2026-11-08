#! The base system: what every Golconda image contains.
#!
#! A built-in component (`lib/components.nix`), with `/network`,
#! `/security`, `/factory` and `/vars`: every system has it, composed first.
#! Its table only configures it; a configuration need not have one.
#!
#! Packages: systemd, dbus-broker, dash (linked as /usr/bin/sh; the image
#! has no bash), uutils-coreutils, tpm2-tss (only systemd's dlopen reaches
#! it), e2fsprogs (mkfs.ext4 and fsck.ext4 for the root partition systemd-repart
#! makes at first boot), cacert (Mozilla's roots, one bundle), tzdata
#! (/usr/share/zoneinfo), hwdb (systemd's hardware database, compiled, at
#! /usr/lib/udev/hwdb.bin) and the kernel (consumed later by the UKI builder).
#! No GNU coreutils.
#!
#! Units enabled: dbus.socket (wanted by sockets.target), dbus-broker.service
#! (as the dbus.service alias), systemd-networkd, systemd-resolved,
#! systemd-timesyncd. The `dbus.socket` unit is written as a file, not as a
#! typed unit: dbus-broker does not ship it.
#!
#! Boot health: `golconda-health-network.service` fails unless networkd has a
#! link with a routable address, and boot-complete.target requires it (the
#! `.requires` link) and is ordered after it. A candidate that boots without a
#! usable network therefore does not reach boot-complete.target and is not
#! blessed (docs/design/boot.md).
#!
#! Boot loader: `golconda-loader-update.service` runs
#! `/usr/lib/golconda/golconda-loader-update` once a counted boot is blessed
#! (wanted by and Requisite= `systemd-bless-boot.service`). It copies the
#! signed systemd-boot in `/usr/lib/systemd/boot/efi/` (the image builder puts
#! it there) and `/usr/lib/golconda/loader.conf` to the ESP when their content
#! differs; `systemd-boot-update.service` is turned off by a drop-in
#! (docs/design/bootloader.md).
#!
#! Links, besides the `/usr/bin` links the image builder makes for the packages:
#! - farm links for systemd's own directories (`/usr/lib/systemd`,
#!   `/usr/lib/udev`, `/usr/lib/sysusers.d`, `/usr/lib/tmpfiles.d`);
#! - dlopen links: every soname systemd opens at run time, in `/usr/lib`;
#! - `/usr/bin` links for the util-linux and e2fsprogs executables that mount
#!   units, systemd-fsck and udev rules exec (the whole packages would bring
#!   100 more tools).
#! - `/usr/share/ca-certificates/ca-bundle.crt`: cacert's Mozilla bundle, the
#!   one CA file of the image;
#! - `/usr/share/zoneinfo`: tzdata's zone database, the one time zone source.
#!
#! Files: the timesyncd and journald drop-ins, and
#! `/usr/lib/repart.d/30-root.conf` (the root partition systemd-repart makes
#! at first boot, rendered from `image/repart.nix`). Tmpfiles lines: `L /bin`, `L /sbin` and `L /lib`, the
#! merged-`/usr` links on the root partition.
#! `L /etc/ssl/cert.pem` and `L /etc/ssl/certs/ca-certificates.crt`, the
#! paths OpenSSL and curl read by default: `openssl version -d` says
#! OPENSSLDIR=/etc/ssl, so OpenSSL reads /etc/ssl/cert.pem, and curl is built
#! with CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt. Both link the one
#! bundle in /usr, so an update carries it and /etc holds no copy.
#! `L /etc/localtime` is the factory's line: it links `/usr/share/zoneinfo/<timezone>`, UTC by default.
#!
#! Unit drop-ins (a link to /dev/null cannot mask a unit the systemd farm
#! already ships): systemd-firstboot.service runs without prompts (no local
#! login, so no root password; it still applies `firstboot.*` credentials),
#! ldconfig.service skips without /usr/bin/ldconfig, modprobe@.service skips
#! without /usr/bin/modprobe (monolithic kernel, no kmod).
#!
#! IMDS (cloud instance metadata): systemd's units for it (the daemon and
#! its socket, the early network, the metrics socket, the import) carry
#! `ConditionPathExists=/usr/lib/golconda/imds`, a file only `/imds` ships:
#! without `/imds` nothing reads the metadata, also on a cloud that hwdb
#! names, and the initrd (built from /base alone) never does.
#!
#! Locale: C.UTF-8 via /usr/lib/locale.conf (PID 1 reads it before /etc
#! exists, so the factory cannot provide it).
#!
#! Options: `/base.ntp` (NTP servers for timesyncd), `/base.journalMaxUse`
#! (journal retention).
{ types, ... }:
let
  inherit (builtins) concatStringsSep;
  inherit (types) listOf string;

  inherit (import ../lib/text.nix) lines;

  # systemd's fallback NTP pool (from timesyncd.c)
  defaultNtp = [
    "0.pool.ntp.org"
    "1.pool.ntp.org"
    "2.pool.ntp.org"
    "3.pool.ntp.org"
  ];

in
{
  name = "base";

  inputs.pkgs.path = "/pkgs";

  options = {
    ntp = {
      type = listOf string;
      default = defaultNtp;
      description = "NTP server pool for systemd-timesyncd. Default: systemd's fallback pool.";
    };
    journalMaxUse = {
      type = string;
      default = "512M";
      description = "SystemMaxUse= for journald: maximum disk space the journal may use.";
    };
  };

  impl =
    { options, results }:
    let
      set = results.pkgs.target;
      p = set.pkgs;

      # The rest of the fragment is in parts/, one concern each; this file merges them.
      # Each part returns the fragment fields it fills.
      boot = import ./parts/boot.nix; # the health gate, the loader update, the /etc link step
      dbus = import ./parts/dbus.nix { inherit p; }; # the system bus on dbus-broker
      dropIns = import ./parts/drop-ins.nix; # conditions for units the systemd farm ships
      imds = import ./parts/imds.nix; # systemd's IMDS units: off without /imds
      usrLinks = import ./parts/links.nix { inherit p; }; # the /usr links into the packages

      # timesyncd drop-in
      timesyncdConf = lines [
        "# Generated by Golconda (/base)"
        "[Time]"
        "NTP=${concatStringsSep " " options.ntp}"
      ];

      # journald drop-in
      journaldConf = lines [
        "# Generated by Golconda (/base)"
        "[Journal]"
        "SystemMaxUse=${options.journalMaxUse}"
        # the screen (tty1) shows the journal as the serial console shows the boot
        "ForwardToConsole=yes"
        "TTYPath=/dev/tty1"
        "MaxLevelConsole=info"
      ];

      # repart.d: the root partition, made by systemd-repart in the initrd at first boot
      # (docs/design/layout.md); the image's own partitions are the image builder's
      # (lib/image/disk.nix renders the rest of image/repart.nix)
      rootRepart = (import ../lib/ini.nix).render (import ../../image/repart.nix)."30-root";

      # locale.conf: PID 1 reads /usr/lib/locale.conf before /etc exists
      # (the factory uses tmpfiles, which runs after PID 1 sets the locale)
      localeConf = "LANG=C.UTF-8\n";

      # Unit enablement: .wants links for static enablement. systemd-networkd,
      # systemd-resolved, systemd-timesyncd enabled via their target's .wants directories
      # (dbus.socket is in parts/dbus.nix, golconda-etc-links.service in parts/boot.nix).
      wantsLinks = {
        # networkd
        "/usr/lib/systemd/system/multi-user.target.wants/systemd-networkd.service" = {
          target = "../systemd-networkd.service";
          kind = "explicit";
        };
        "/usr/lib/systemd/system/sockets.target.wants/systemd-networkd.socket" = {
          target = "../systemd-networkd.socket";
          kind = "explicit";
        };
        # resolved
        "/usr/lib/systemd/system/multi-user.target.wants/systemd-resolved.service" = {
          target = "../systemd-resolved.service";
          kind = "explicit";
        };
        # timesyncd
        "/usr/lib/systemd/system/sysinit.target.wants/systemd-timesyncd.service" = {
          target = "../systemd-timesyncd.service";
          kind = "explicit";
        };
      };
    in
    {
      packages = [
        p.systemd
        p.dbus-broker
        p.dash
        p.uutils-coreutils
        p.tpm2-tss # dlopen only (see parts/links.nix): nothing else brings it into the closure
        p.e2fsprogs # mkfs.ext4 and fsck.ext4: repart makes the root partition at first boot
        p.cacert # the one CA bundle: /usr/share/ca-certificates/ca-bundle.crt
        p.tzdata # the zone database: /usr/share/zoneinfo
        p.hwdb # the compiled hardware database: /usr/lib/udev/hwdb.bin
        p.linux-kernel # kernel; UKI builder consumes it
      ];

      inherit (boot) units;

      files =
        dropIns.files
        // imds.files
        // boot.files
        // dbus.files
        // {
          "/usr/lib/systemd/timesyncd.conf.d/golconda.conf" = timesyncdConf;
          "/usr/lib/systemd/journald.conf.d/golconda.conf" = journaldConf;
          "/usr/lib/locale.conf" = localeConf;
          "/usr/lib/repart.d/30-root.conf" = rootRepart;
        };

      # path -> { target; kind; }, the shape the composer takes
      links = wantsLinks // boot.links // dbus.links // usrLinks.links;

      inherit (dbus) sysusers;

      # merged /usr on the root partition: #!/bin/sh and friends. The root partition starts
      # empty (image/repart.nix makes only directories), so tmpfiles makes these links at
      # boot. Plus the CA links of parts/links.nix.
      tmpfiles = [
        "L /bin - - - - usr/bin"
        "L /sbin - - - - usr/bin"
        "L /lib - - - - usr/lib"
      ]
      ++ usrLinks.tmpfiles;
    };
}
