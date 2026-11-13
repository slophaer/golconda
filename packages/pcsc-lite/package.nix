# PC/SC Lite: pcscd, the daemon that owns the smart card readers, and libpcsclite, the client
# library that yubico-piv-tool and its PKCS#11 module (libykcs11.so) talk to it through. A tool
# of the release host (packages/yubikey-tools), never in the image: the image has no smart card
# code. USB readers come through libusb (no udev, no systemd, no polkit); the reader driver, ccid,
# is a package of its own that pcscd finds by PCSCLITE_HP_DROPDIR (ccid's exports.env).
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "pcsc-lite";
  uses = [ "meson" ];
  # pcscd's socket directory and pid file are compiled-in paths (/run/pcscd). The patch lets
  # PCSCLITE_IPC_DIR name another directory at run time, for a daemon that is not root's: the
  # package test runs one that way, and so can anyone debugging a reader without root
  patches = [ ./ipc-dir-env.patch ];
  meson.defs = {
    sbindir = "bin"; # pcscd is a daemon for root, but this package's executables live in bin/
    libusb = true; # USB hotplug without udev
    libudev = false;
    libsystemd = false;
    polkit = false; # any local user may use the card, as without polkit everywhere
    usb = true;
    serial = false;
    embedded = false;
    # ambient paths: the socket directory, and where pcscd looks for USB drivers when
    # PCSCLITE_HP_DROPDIR does not name them
    ipcdir = "/run/pcscd";
    usbdropdir = "/usr/lib/pcsc/drivers";
  };
  # install puts a systemd unit that names $out/bin/pcscd, a sysusers file and /etc/default/pcscd
  # into the package whether or not systemd is used. A release host starts pcscd by hand
  phases.after."meson.install" = {
    name = "drop-service-files";
    run = ''
      for d in [lib/systemd sysusers.d etc] {
        rm -rf $"($c.out)/($d)"
      }
    '';
  };
  # libpcsclite.so.1 only forwards: it dlopen()s libpcsclite_real.so.1 by soname (libredirect.c).
  # ld.so searches the caller's RUNPATH and Golconda has no ld.so.cache, so the library's own
  # directory goes there
  cc.ldflags = [ "-Wl,-rpath,$ORIGIN" ];
  buildDependencies = [
    buildPkgs.flex # the reader.conf and driver plist parsers
    buildPkgs.perl # pod2man, for the pcsc-spy page that meson makes while it configures
  ];
  dependencies = [ pkgs.libusb ];
  # the suite is the unit tests of the wire protocol; tests/packages/pcsc-lite runs the daemon
  tests.run = false;
  bin = [ "pcscd" ];
  platforms.os = [ "linux" ];
}
