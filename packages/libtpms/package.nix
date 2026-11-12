# libtpms: the TPM 2.0 (and 1.2) implementation swtpm runs, on OpenSSL (the one TLS and crypto
# library of the set). A development tool's library, not part of an image. The GitHub archive has
# no configure: autoreconf first, as its autogen.sh does
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "libtpms";
  uses = [ "autotools" ];
  patches = [ ./getplaintext-const.patch ];
  buildDependencies = [
    buildPkgs.autoconf
    buildPkgs.automake
    buildPkgs.libtool
    buildPkgs.pkgconf
    # pod2man, for the man pages
    buildPkgs.perl
  ];
  dependencies = [ pkgs.openssl ];
  phases.before."autotools.configure" = [
    {
      name = "autoreconf";
      run = ''
        cd $c.src
        x autoreconf --force --install
      '';
    }
  ];
  autotools.flags = [
    "--with-openssl"
    "--with-tpm2"
    # its own -fstack-protector and -D_FORTIFY_SOURCE=2: cc has them
    "--disable-hardening"
  ];
  platforms.os = [ "linux" ];
}
