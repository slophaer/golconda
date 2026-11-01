# erofs-utils: tools for EROFS filesystem (Enhanced Read-Only File System)
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "erofs-utils";
  uses = [ "autotools" ];
  buildDependencies = [
    buildPkgs.autoconf
    buildPkgs.automake
    buildPkgs.libtool
    buildPkgs.pkgconf
  ];
  dependencies = [
    pkgs.lz4
    pkgs.util-linux # libuuid
    pkgs.zlib
    pkgs.xz # liblzma
    pkgs.zstd
  ];
  phases.before."autotools.configure" = [
    {
      name = "autogen";
      run = ''
        cd $c.src
        x ./autogen.sh
      '';
    }
  ];
  autotools.flags = [
    "--disable-fuse"
  ];
  tests.run = false;
  bin = [
    "mkfs.erofs"
    "fsck.erofs"
    "dump.erofs"
  ];
  platforms.os = [ "linux" ];
}
