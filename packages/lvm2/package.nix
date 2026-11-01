# lvm2: device-mapper library and tools
#
# Configure flags for dm udev synchronization:
# - --enable-udev_rules: install 10-dm.rules, 13-dm-disk.rules, 95-dm-notify.rules
# - --with-udevdir=$out/lib/udev: relocatable udev rules path
# - --disable-udev_sync: disabled because libudev requires systemd (WP4)
# - --disable-udev-systemd-background-jobs: no systemd integration
#
# LIMITATION: Without --enable-udev_sync, dmsetup lacks the udevcomplete command.
# When systemd/libudev is available (WP4), rebuild with --enable-udev_sync.
# The semaphore-based dm_udev_wait/dm_udev_complete will then work with the rules.
#
# For initrd: include lib/udev/rules.d/{10-dm,13-dm-disk,95-dm-notify}.rules and dmsetup.
{
  package,
  pkgs,
}:
package {
  name = "lvm2";
  uses = [ "autotools" ];
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

      # udev rules: install for future udev_sync when systemd exists
      "--enable-udev_rules"
      "--with-udevdir=\${prefix}/lib/udev/rules.d"

      # Disable features requiring libudev (systemd not yet available)
      "--disable-udev_sync" # requires libudev >= 143
      "--disable-udev-systemd-background-jobs"
      "--without-udev" # don't link libudev

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
  # udev rules have absolute paths by design; make them use {prefix} placeholder
  # so initrd/system install can substitute the actual path
  phases.after."autotools.install" = [
    {
      name = "fix-udev-rules";
      run = ''
        let c = (ctx)
        cd $c.out
        for f in (glob lib/udev/rules.d/*.rules) {
          ^chmod u+w $f
          open --raw $f | str replace -a $c.out '{prefix}' | save -f $f
        }
      '';
    }
  ];
  # Tests need root and devices
  tests.run = false;
  # dmsetup --version fails without /dev/mapper/control (kernel device-mapper)
  tests.version = false;
  bin = [
    "dmsetup"
  ];
  platforms.os = [ "linux" ];
}
