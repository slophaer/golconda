# gen-init-cpio: the kernel's own initramfs writer (usr/gen_init_cpio.c), which builds the
# initrd's newc cpio (lib/image/initrd.nu). It reads a list of entries (file, dir, slink, nod,
# pipe, sock: name, mode, uid, gid) and writes them in that order. The headers come from the list
# and from counters, never from the build directory: inode numbers count up from 721, the device
# is 3:1 for every entry, a directory has nlink 2, a file 1 (or the number of names on its line),
# and with -t every entry has that mtime. The same list gives the same bytes.
#
# The source is the kernel tree packages/kernel pins, so there is no second pin to keep in step:
# a kernel update updates this too. One C file with only libc headers; no sources.toml, so the
# SBOM purl is the kernel's plus a subpath (sourceOf). Not part of an image.
{ package, pkgs }:
package {
  name = "gen-init-cpio";
  inherit (pkgs.linux-kernel) version;
  source = "${pkgs.linux-kernel.src}/usr";
  sourceOf = {
    package = pkgs.linux-kernel;
    subpath = "usr/gen_init_cpio.c";
  };
  phases = [
    {
      name = "build";
      run = ''
        x cc -o $"($c.build)/gen_init_cpio" gen_init_cpio.c
        install-bins $c.build [gen_init_cpio]
      '';
    }
  ];
  bin = [ "gen_init_cpio" ];
  # no --version: -h prints the usage
  tests.version = false;
}
