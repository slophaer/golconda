# Part of /base (modules/base/default.nix merges it): the /usr links into the
# packages. /usr/bin/sh, the util-linux and e2fsprogs tools, systemd's farm
# directories, the NSS modules, the PAM module directories, the zone database, the
# compiled hwdb and lvm2's dm rules. (The CA bundle and its /etc links are /trust's.)
# `p` is the package set. Returns { links; }.
{ p }:
let
  inherit (builtins) listToAttrs;

  # The zone database: /etc/localtime (the factory's tmpfiles line) links
  # /usr/share/zoneinfo/<timezone>, UTC by default. One directory link: the
  # zone files are data that no $ORIGIN rule reaches.
  zoneinfoLinks = {
    "/usr/share/zoneinfo" = {
      target = "${p.tzdata}/share/zoneinfo";
      kind = "explicit";
    };
  };

  # The compiled hardware database (packages/hwdb). systemd ships no hwdb.bin, so this
  # file sits beside the lib/udev farm without a clash. A file, not a directory link:
  # /usr/lib/udev is systemd's farm.
  hwdbLinks = {
    "/usr/lib/udev/hwdb.bin" = {
      target = "${p.hwdb}/lib/udev/hwdb.bin";
      kind = "explicit";
    };
  };

  # The device-mapper rules of lvm2 (a farm package: they exec /usr/bin/dmsetup, and /base brings
  # dmsetup with lvm2). 10-dm names the device and links /dev/mapper/<name>; 13-dm-disk adds the
  # blkid data (ID_FS_USAGE) without which systemd's 99-systemd.rules keeps a CRYPT-* device, the
  # dm-verity /usr, at SYSTEMD_READY=0. With both, /dev/mapper/usr exists and
  # dev-mapper-usr.device, which usr.mount requires, is active, in the initrd and on the host.
  # 95-dm-notify is left out: it answers the udev cookies of libdevmapper, and lvm2 is built
  # without udev_sync (packages/lvm2), so nothing waits for one. Files, not a directory link:
  # /usr/lib/udev is systemd's farm.
  dmRuleLinks = listToAttrs (
    map
      (r: {
        name = "/usr/lib/udev/rules.d/${r}";
        value = {
          target = "${p.lvm2}/lib/udev/rules.d/${r}";
          kind = "explicit";
        };
      })
      [
        "10-dm.rules"
        "13-dm-disk.rules"
      ]
  );

  # PAM modules: Linux-PAM loads a relative module name from /usr/lib/security/, and the
  # factory's stacks name <package>/<module>. Each package's module directory is one
  # directory link: repkgs writes DT_NEEDED as $ORIGIN/../../../<dep>/lib/..., $ORIGIN is
  # the directory of the path PAM opens, and only a directory link makes `..` reach the
  # store (a file link breaks pam_unix's libcrypt; merged copies break $ORIGIN/../libpam).
  pamLinks = {
    "/usr/lib/security/linux-pam" = {
      target = "${p.linux-pam}/lib/security";
      kind = "explicit";
    };
    "/usr/lib/security/systemd" = {
      target = "${p.systemd}/lib/security";
      kind = "explicit";
    };
  };

  # dash is /bin/sh (/bin -> usr/bin is made by the image builder).
  shLinks = {
    "/usr/bin/sh" = {
      target = "${p.dash}/bin/dash";
      kind = "explicit";
    };
  };

  # Farm links: directories the image builder expands file by file, subdirectories
  # included: systemd's lib/systemd (PID 1, the executor, udevd, every daemon,
  # libsystemd-shared, the units with their static .wants/, generators, presets, catalog),
  # lib/udev (rules, hwdb, the id helpers), sysusers.d, tmpfiles.d; all by systemd's
  # compiled-in /usr/lib/... paths. The D-Bus farm links are in parts/dbus.nix.
  farmLinks = {
    "/usr/lib/systemd" = {
      target = "${p.systemd}/lib/systemd";
      kind = "farm";
    };
    "/usr/lib/udev" = {
      target = "${p.systemd}/lib/udev";
      kind = "farm";
    };
    "/usr/lib/sysusers.d" = {
      target = "${p.systemd}/lib/sysusers.d";
      kind = "farm";
    };
    "/usr/lib/tmpfiles.d" = {
      target = "${p.systemd}/lib/tmpfiles.d";
      kind = "farm";
    };
    # NvPCR definitions: systemd-pcrextend (pcrproduct, pcrlogin@) and cryptsetup look
    # them up in /usr/lib/nvpcr
    "/usr/lib/nvpcr" = {
      target = "${p.systemd}/lib/nvpcr";
      kind = "farm";
    };
  };

  # dlopen: glibc's NSS modules, which glibc opens by soname from its default directories
  # (nsswitch.conf names `systemd` and `myhostname`); a caller's RUNPATH does not reach
  # them. The builder checks they resolve. The libraries systemd itself dlopens (its ELF
  # .note.dlopen) need no link: dlopen searches the caller's RUNPATH, the fork's RUNPATH
  # names every dependency's lib/, and the fork fails a package's build when a noted
  # soname that a dependency has is out of its reach (builder/finish.nu dlopen-check).
  dlopenSonames = {
    "libnss_systemd.so.2" = p.systemd;
    "libnss_myhostname.so.2" = p.systemd;
  };
  dlopenLinks = listToAttrs (
    map (so: {
      name = "/usr/lib/${so}";
      value = {
        target = "${dlopenSonames.${so}}/lib/${so}";
        kind = "dlopen";
      };
    }) (builtins.attrNames dlopenSonames)
  );

  # mount units and systemd-fsck exec these from util-linux (in the closure as systemd's
  # library dependency; the whole package would bring 100 more tools). blkid: lvm2's
  # 13-dm-disk.rules probes a dm device with it, and without ID_FS_USAGE systemd's
  # 99-systemd.rules keeps a CRYPT-* device (dm-verity's /usr) at SYSTEMD_READY=0 forever.
  toolLinks =
    listToAttrs (
      map
        (b: {
          name = "/usr/bin/${b}";
          value = {
            target = "${p.util-linux}/bin/${b}";
            kind = "explicit";
          };
        })
        [
          "mount"
          "umount"
          "fsck"
          "blkid"
        ]
    )
    // {
      "/usr/bin/fsck.ext4" = {
        target = "${p.e2fsprogs}/bin/fsck.ext4";
        kind = "explicit";
      };
      # golconda-failed-boots writes its EFI variable, which efivarfs makes immutable
      "/usr/bin/chattr" = {
        target = "${p.e2fsprogs}/bin/chattr";
        kind = "explicit";
      };
    };
in
{
  links =
    shLinks
    // toolLinks
    // farmLinks
    // dlopenLinks
    // pamLinks
    // zoneinfoLinks
    // hwdbLinks
    // dmRuleLinks;
}
