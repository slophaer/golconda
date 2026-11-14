# e2fsprogs: ext2/ext3/ext4 filesystem utilities
{
  package,
  pkgs,
}:
package {
  name = "e2fsprogs";
  uses = [ "autotools" ];
  # Relocatable paths: /etc for the configuration files, share/ relative to compile_et and
  # mk_cmds, the e2scrub helpers from PATH
  patches = [ ./relocatable-paths.patch ];
  autotools.flags = [
    "--disable-libuuid" # use util-linux's libuuid
    "--disable-libblkid" # use util-linux's libblkid
    "--disable-uuidd" # no uuid daemon
    "--disable-fsck" # use util-linux's fsck wrapper
    "--disable-fuse2fs" # no FUSE support
    "--disable-nls" # no translations
    "--disable-defrag" # no online defrag (needs -ldl for dlopen)
    # No --sysconfdir=/etc: without a declared prefix the install would write to /etc. The
    # binaries read /etc/mke2fs.conf (the patch); the image has none, and mke2fs then uses its
    # compiled-in copy of the same file (misc/default_profile.c, made from mke2fs.conf at build
    # time). The etc/mke2fs.conf the install leaves in the package is linked nowhere.
  ];
  dependencies = [
    pkgs.util-linux # for libuuid and libblkid
  ];
  # tests need root and real block devices
  tests.run = false;
  # e2fsprogs uses -V for version, not --version
  tests.version = "-V";
  bin = [
    "mkfs.ext4"
    "e2fsck"
    "tune2fs"
    "dumpe2fs"
    "resize2fs"
    "mke2fs"
  ];
  platforms.os = [ "linux" ];
}
