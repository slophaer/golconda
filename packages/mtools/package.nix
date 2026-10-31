# mtools: mcopy and mmd, which systemd-repart runs to fill a vfat partition (the ESP) offline.
# Build-time only, like dosfstools. General enough for the repkgs fork; here until it moves.
{ package }:
package {
  name = "mtools";
  uses = [ "autotools" ];
  autotools.flags = [
    "--without-x" # no floppyd GUI bits
    "--disable-floppyd"
    "--sysconfdir=/etc" # the compiled-in mtools.conf path; never present at build time (MTOOLS_SKIP_CHECK)
  ];
  tests.version = "mtools -V";
}
