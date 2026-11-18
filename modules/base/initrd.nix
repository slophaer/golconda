# What the initrd runs of /base, by name. lib/image/initrd.nix takes these from the image's
# composition, so a downstream replacement holds there too; a name that /base does not have stops
# the build. Every unit drop-in and PID 1 setting of /base goes to the initrd as well, without a
# name: a drop-in for a unit that the initrd does not run has no effect there. docs/design/boot.md.
#
# systemd (its initrd units and generators, from the farm), udev with lvm2's dm rules for the
# verity /usr, dash, the tools the boot runs (repart's mkfs.ext4, fsck, mount, blkid; chattr and
# coreutils for the failed-boot counter), hwdb (the IMDS generator reads it, and the IMDS drop-ins
# keep its units off), the locale, the root partition, the failed-boot counter and the emergency
# reboot.
{
  packages = [
    "systemd"
    "dash"
    "uutils-coreutils"
    "e2fsprogs"
    "lvm2"
    "hwdb"
  ];
  units = [
    "golconda-failed-boots.service"
    "golconda-emergency-reboot.service"
  ];
  files = [
    "/usr/lib/locale.conf"
    "/usr/lib/repart.d/30-root.conf"
    "/usr/lib/golconda/golconda-failed-boots"
  ];
  links = [
    "/usr/bin/sh"
    "/usr/bin/mount"
    "/usr/bin/umount"
    "/usr/bin/fsck"
    "/usr/bin/blkid"
    "/usr/bin/fsck.ext4"
    "/usr/bin/chattr"
    "/usr/lib/systemd"
    "/usr/lib/udev"
    "/usr/lib/sysusers.d"
    "/usr/lib/tmpfiles.d"
    "/usr/lib/nvpcr"
    "/usr/lib/udev/hwdb.bin"
    "/usr/lib/udev/rules.d/10-dm.rules"
    "/usr/lib/udev/rules.d/13-dm-disk.rules"
    "/usr/lib/systemd/system/emergency.target.wants/golconda-emergency-reboot.service"
    "/usr/lib/systemd/system/sysinit.target.wants/golconda-failed-boots.service"
  ];
}
