# hwdb: systemd's hardware database, compiled into lib/udev/hwdb.bin. /base links it to
# /usr/lib/udev/hwdb.bin.
#
# Why compiled at build time: udev, the IMDS generator and networkctl read only hwdb.bin, never
# the sources, and systemd-hwdb-update.service would write it to /etc/udev on the machine at
# first boot (ConditionNeedsUpdate=/etc). With /usr/lib/udev/hwdb.bin present the service does
# nothing. Without any, every hwdb lookup fails with no error: the udev properties are missing.
#
# The sources are the target systemd's own lib/udev/hwdb.d, so the database always matches the
# udev that reads it and carries its version; no second pin can drift from packages/systemd. The
# compiler is the build machine's systemd-hwdb (buildDependencies). Only the files in files.nix
# go in; a file there that systemd no longer ships fails the build, so a rename is noticed.
# The output is the same bytes for the same inputs.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "hwdb";
  inherit (pkgs.systemd) version;
  source = "${pkgs.systemd}/lib/udev/hwdb.d";
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
