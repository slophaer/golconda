# e2fsprogs: ext2/ext3/ext4 filesystem utilities
{
  package,
  pkgs,
}:
package {
  name = "e2fsprogs";
  uses = [ "autotools" ];
  # Make config paths relocatable (absolute /etc or relative to binary)
  phases.before."autotools.configure" = [
    {
      name = "fix-hardcoded-paths";
      run = ''
        cd $c.src
        # Use /etc for runtime config lookup instead of store path
        sed -i 's|ROOT_SYSCONFDIR.*"@root_sysconfdir@"|ROOT_SYSCONFDIR "/etc"|' lib/dirpaths.h.in
        # Scripts: use relative paths for share/ dirs
        sed -i 's|DIR=@datadir@/ss|DIR="''${0%/*}/../share/ss"|' lib/ss/mk_cmds.sh.in
        sed -i 's|DIR=@datadir@/et|DIR="''${0%/*}/../share/et"|' lib/et/compile_et.sh.in
        # e2scrub scripts: use /etc for config, commands on PATH
        sed -i 's|@root_sysconfdir@|/etc|g' scrub/e2scrub.in scrub/e2scrub_all.in
        sed -i 's|@root_sbindir@/e2fsck|e2fsck|g' scrub/e2scrub.in
        sed -i 's|@root_sbindir@/e2scrub|e2scrub|g' scrub/e2scrub_all.in
        # e2scrub also calls tune2fs, e2image
        sed -i 's|@root_sbindir@/tune2fs|tune2fs|g' scrub/e2scrub.in
        sed -i 's|@root_sbindir@/e2image|e2image|g' scrub/e2scrub.in
      '';
    }
  ];
  autotools.flags = [
    "--disable-libuuid" # use util-linux's libuuid
    "--disable-libblkid" # use util-linux's libblkid
    "--disable-uuidd" # no uuid daemon
    "--disable-fsck" # use util-linux's fsck wrapper
    "--disable-fuse2fs" # no FUSE support
    "--disable-nls" # no translations
    "--disable-defrag" # no online defrag (needs -ldl for dlopen)
    # Note: don't set --sysconfdir=/etc, it causes install to /etc which fails.
    # mke2fs.conf installs to $prefix/etc; the composer symlinks /etc/mke2fs.conf
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
