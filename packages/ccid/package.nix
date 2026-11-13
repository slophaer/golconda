# The generic USB CCID reader driver for pcscd (a bundle: Info.plist and libccid.so), which
# includes the YubiKey's smart card interface. A tool of the release host, never in the image.
# pcscd loads it from PCSCLITE_HP_DROPDIR, which this package exports, so a package that depends
# on ccid starts its programs with the variable set (packages/yubikey-tools).
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "ccid";
  uses = [ "meson" ];
  # upstream installs the bundle where pcsc-lite's .pc file says (the ambient
  # /usr/lib/pcsc/drivers): under this package's libdir instead
  patches = [ ./bundle-dir.patch ];
  meson.defs = {
    udev-rules = false; # pcscd runs as root on the release host
    serial = false;
    class = false;
    zlp = false;
    embedded = false;
  };
  buildDependencies = [
    buildPkgs.flex
    buildPkgs.perl # create_Info_plist.pl
  ];
  dependencies = [
    pkgs.pcsc-lite # headers; the driver is loaded by pcscd, not linked to libpcsclite
    pkgs.libusb
    pkgs.zlib
  ];
  tests.run = false; # upstream has no suite
  tests.version = false; # a driver bundle, no executable
  bin = [ ];
  exports = {
    libDirs = [ ];
    libs = [ ];
    env.PCSCLITE_HP_DROPDIR = "{root}/lib/pcsc/drivers";
  };
  platforms.os = [ "linux" ];
}
