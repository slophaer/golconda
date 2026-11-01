# TPM 2.0 software stack: the libraries systemd's tpm2 support uses (esys, mu, rc, tctildr)
{ package, pkgs }:
package {
  name = "tpm2-tss";
  uses = [ "autotools" ];
  autotools.flags = [
    "--with-crypto=ossl"
    # FAPI and the policy library are the parts that need json-c and curl
    "--disable-fapi"
    "--disable-policy"
    # no TCTI for libtpms, the simulator, SPI or I2C. Device, swtpm, cmd and pcap stay
    "--disable-tcti-mssim"
    "--disable-tcti-libtpms"
    "--disable-tcti-spi-helper"
    "--disable-tcti-spi-ltt2go"
    "--disable-tcti-spidev"
    "--disable-tcti-spi-ftdi"
    "--disable-tcti-i2c-helper"
    "--disable-tcti-i2c-ftdi"
    # no --enable-nodl: systemd dlopens the TCTI itself (src/shared/tpm2-util.c) and calls its
    # Tss2_Tcti_Info, which the TCTI exports only when it is not linked into tctildr/esys. The
    # TCTIs are dlopen()ed by soname, so they need their own directory on RUNPATH ($ORIGIN below)
    "--disable-doxygen-doc"
    "--disable-unit"
    "--disable-integration"
    "--disable-defaultflags" # its own -D_FORTIFY_SOURCE=2 and stack protector flags: cc has them
    "--with-runstatedir=/run"
  ];
  # libtss2-tctildr dlopens the TCTIs by soname (tctildr-dl.c: libtss2-tcti-<name>.so.0), and a
  # relocatable library has no default search path. Its own directory on RUNPATH ($ORIGIN, kept
  # because no NEEDED is served by it) is what makes the dlopen find the sibling TCTIs
  cc.ldflags = [ "-Wl,-rpath,$ORIGIN" ];
  # make install creates the FAPI keystore under var/ even without FAPI, and installs the sysusers
  # file for the `tss` group (tpm-udev.rules) only when systemd-sysusers is on PATH
  phases.after."autotools.install" = {
    name = "tss-user";
    run = ''
      rm -rf $"($c.out)/var"
      mkdir $"($c.out)/lib/sysusers.d"
      cp $"($c.src)/dist/sysusers.d/tpm2-tss.conf" $"($c.out)/lib/sysusers.d"
    '';
  };
  dependencies = [ pkgs.openssl ];
  tests.run = false; # the unit tests are off (cmocka), the integration tests want a TPM
  platforms.os = [ "linux" ];
}
