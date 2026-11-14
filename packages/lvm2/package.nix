# lvm2: the device-mapper library and dmsetup, nothing of LVM itself.
#
# A farm package (prefix = "/usr"): its udev rules (10-dm, 13-dm-disk, 95-dm-notify) exec
# dmsetup as /usr/bin/dmsetup, and the initrd farms lib/udev/rules.d as it is
# (lib/image/initrd.nix). cryptsetup links libdevmapper; the initrd needs the rules and dmsetup
# for /dev/mapper/usr.
#
# udev_sync is off: libdevmapper would link libudev, which is systemd's, and systemd depends on
# cryptsetup, which depends on lvm2: systemd -> cryptsetup -> lvm2 -> libudev is a cycle. Without
# it, libdevmapper does not wait on udev cookies and dmsetup has no udevcomplete; systemd's
# device units do the waiting, and the rules work as they are (`13-dm-disk` needs /usr/bin/blkid,
# modules/base/parts/links.nix). Breaking the cycle needs a libudev built apart from systemd.
{
  package,
  pkgs,
}:
package {
  name = "lvm2";
  uses = [ "autotools" ];
  prefix = "/usr";
  dependencies = [
    pkgs.util-linux # libuuid, libblkid
    pkgs.libaio # async I/O for device-mapper
  ];
  autotools = {
    flags = [
      # Device-mapper only (no full LVM)
      "--enable-devmapper"
      "--enable-cmdlib" # libdm, dmsetup
      "--enable-pkgconfig" # install devmapper.pc for libcryptsetup

      # the dm udev rules, in the prefix's lib/udev/rules.d
      "--enable-udev_rules"
      "--with-udevdir=/usr/lib/udev/rules.d"

      # no libudev: it would close the cycle systemd -> cryptsetup -> lvm2 -> libudev
      "--disable-udev_sync"
      "--disable-udev-systemd-background-jobs"
      "--without-udev"

      # Disable LVM features we don't need
      "--disable-selinux"
      "--disable-dmeventd"
      "--disable-lvmpolld"
      "--disable-lvmlockd-sanlock"
      "--disable-lvmlockd-dlm"
      "--disable-readline"
      "--disable-editline"
      "--disable-blkid_wiping" # avoid libblkid probe issues
      "--disable-nls"
      "--disable-blkdeactivate" # shell script with hardcoded paths

      # Config location
      "--with-confdir=/etc"
    ];
    # Build only device-mapper (not full LVM)
    buildTarget = [ "device-mapper" ];
    installTarget = [ "install_device-mapper" ];
  };
  # Tests need root and devices
  tests.run = false;
  # dmsetup --version fails without /dev/mapper/control (kernel device-mapper)
  tests.version = false;
  bin = [
    "dmsetup"
  ];
  platforms.os = [ "linux" ];
}
