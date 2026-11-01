# btrfs-progs: btrfs, mkfs.btrfs, btrfs check and the other btrfs utilities
{
  package,
  pkgs,
}:
package {
  name = "btrfs-progs";
  uses = [ "autotools" ];
  autotools.outOfTree = false; # the Makefile is in the source tree
  autotools.flags = [
    "--disable-documentation" # asciidoc and sphinx
    "--disable-python" # the python bindings
    "--disable-convert" # ext2 and reiserfs conversion, needs e2fsprogs and reiserfs libraries
    "--disable-lzo" # no lzo2 package; zlib and zstd compression stay
    "--disable-libudev" # device scanning through udev
  ];
  dependencies = [
    pkgs.util-linux # libblkid, libuuid
    pkgs.zlib
    pkgs.zstd
  ];
  # the test suite needs root, loop devices and mounts
  tests.run = false;
  tests.version = "btrfs --version";
  bin = [
    "btrfs"
    "btrfs-find-root"
    "btrfs-image"
    "btrfs-map-logical"
    "btrfs-select-super"
    "btrfsck"
    "btrfstune"
    "fsck.btrfs"
    "mkfs.btrfs"
  ];
  platforms.os = [ "linux" ];
}
