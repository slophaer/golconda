# dosfstools: FAT filesystem utilities (mkfs.fat, fsck.fat)
{ package }:
package {
  name = "dosfstools";
  uses = [ "autotools" ];
  # mkfs.fat takes its clock from SOURCE_DATE_EPOCH: upstream's commit after 4.2, the last
  # release (PR #106). systemd-repart passes the variable on, so the ESP in disk.raw is the same
  # bytes on every signing (tests/packages/dosfstools)
  patches = [ ./source-date-epoch.patch ];
  autotools.flags = [
    "--enable-compat-symlinks" # mkfs.vfat -> mkfs.fat, etc.
    "--without-udev" # no udev rules
    "--disable-nls"
  ];
  # tests need root and devices
  tests.run = false;
  # dosfstools doesn't have --version; version is printed when running but
  # always with exit code != 0 (requires arguments). Disable version check;
  # smoke test will verify functionality
  tests.version = false;
  bin = [
    "mkfs.fat"
    "fsck.fat"
    "fatlabel"
  ];
  platforms.os = [ "linux" ];
}
