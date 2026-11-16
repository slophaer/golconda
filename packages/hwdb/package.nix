# hwdb: systemd's hardware database, compiled into lib/udev/hwdb.bin; /base links it to
# /usr/lib/udev/hwdb.bin (docs/design/packaging.md).
#
# Compiled at build time: udev reads only hwdb.bin, and without it systemd-hwdb-update.service
# would write one to /etc on the first boot. The sources are the target systemd's own hwdb.d, so
# the database matches the udev that reads it. Only the files in files.nix go in; a file there
# that systemd does not ship fails the build.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "hwdb";
  inherit (pkgs.systemd) version;
  source = "${pkgs.systemd}/lib/udev/hwdb.d";
  sourceOf = {
    package = pkgs.systemd;
    subpath = "hwdb.d";
  };
  buildDependencies = [ buildPkgs.systemd ]; # systemd-hwdb
  env.GOLCONDA_HWDB_FILES = builtins.toJSON (import ./files.nix);
  phases = [
    {
      name = "install";
      run = ''
        let c = (ctx)
        let root = $"($env.TMPDIR? | default /tmp)/hwdb-root"
        let dir = $"($root)/usr/lib/udev/hwdb.d"
        mkdir $dir
        for f in ($env.GOLCONDA_HWDB_FILES | from json) {
          let p = $"($c.src)/($f)"
          if not ($p | path exists) {
            error make {msg: $"hwdb: ($f) is not in systemd's hwdb.d"}
          }
          ^cp $p $dir
        }
        ^systemd-hwdb $"--root=($root)" --usr update
        mkdir $"($c.out)/lib/udev"
        ^cp $"($root)/usr/lib/udev/hwdb.bin" $"($c.out)/lib/udev/hwdb.bin"
      '';
    }
  ];
  # data only: no libraries, no programs
  exports = {
    libDirs = [ ];
    libs = [ ];
  };
  bin = [ ];
  tests.version = false;
  platforms.os = [ "linux" ];
}
