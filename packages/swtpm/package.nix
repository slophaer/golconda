# swtpm: the software TPM scripts/boot-test gives its virtual machine (`swtpm socket --tpm2`, QEMU's
# emulator TPM). A development tool, not part of an image. Built without GnuTLS: it is needed only
# by swtpm_cert, which makes the TPM's EK and platform certificates for swtpm_setup --create-ek-cert,
# and the boot test starts swtpm on an empty state directory with no certificates. OpenSSL stays the
# one TLS and crypto library. No CUSE (/dev/vtpm), seccomp profile or SELinux policy: the boot
# test uses the socket only. The GitHub archive has no configure: autoreconf first
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "swtpm";
  uses = [ "autotools" ];
  buildDependencies = [
    buildPkgs.autoconf
    buildPkgs.automake
    buildPkgs.libtool
    buildPkgs.pkgconf
    # pod2man, for the man pages
    buildPkgs.perl
    # configure checks the default PCR banks with a bash regular expression, and wants python
    # (AM_PATH_PYTHON) although only the tests run it
    buildPkgs.bash
    buildPkgs.cpython
  ];
  dependencies = [
    pkgs.libtpms
    pkgs.json-glib
    pkgs.glib
    pkgs.openssl
    pkgs.libtasn1
    # swtpm_localca, built with the rest, computes with big numbers
    pkgs.gmp
  ];
  phases.before."autotools.configure" = [
    {
      name = "autoreconf";
      run = ''
        cd $c.src
        mkdir m4
        x autoreconf --force --install
      '';
    }
  ];
  # swtpm_setup and swtpm_localca make a TPM's certificates and state ahead of time; they name the
  # install prefix (compiled-in sysconfdir and bindir, and the configuration files they install),
  # which a relocatable package must not, and the boot test does not run them. Removed with their
  # configuration, as are the installed tests
  phases.after."autotools.install" = {
    name = "no-setup";
    run = ''
      rm -rf $"($c.out)/bin/swtpm_setup" $"($c.out)/bin/swtpm_localca" $"($c.out)/etc" $"($c.out)/share/swtpm" $"($c.out)/libexec" $"($c.out)/share/man/man5"
      for p in [swtpm_setup swtpm_localca swtpm-localca swtpm-create-tpmca] {
        for f in (glob $"($c.out)/share/man/man8/($p).*") { rm $f }
      }
    '';
  };
  autotools.flags = [
    "--with-openssl"
    "--without-gnutls"
    "--without-cuse"
    "--without-seccomp"
    "--without-selinux"
    # the test suite needs expect, socat and tpm2-tools; the package's own test talks to swtpm
    "--disable-tests"
    "--disable-hardening"
  ];
  tests.run = false;
  bin = [
    "swtpm"
    "swtpm_ioctl"
    "swtpm_bios"
  ];
  platforms.os = [ "linux" ];
}
