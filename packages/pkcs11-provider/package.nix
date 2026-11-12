# pkcs11-provider: an OpenSSL 3 provider for keys on a PKCS#11 token. With it the signer's tools
# (systemd-sbsign, systemd-measure through ukify, openssl) take a `pkcs11:` URI where they take a
# key file, and the token signs: the private key never leaves it (lib/image/sign.nu). A tool of
# the release host, never in the image: the image's OpenSSL loads no provider. It loads the
# module that PKCS11_PROVIDER_MODULE names; no default (no p11-kit proxy), so the signer always
# names one (`golconda-sign --pkcs11-module`).
{ package, pkgs }:
package {
  name = "pkcs11-provider";
  uses = [ "meson" ];
  # the provider goes to this package's lib/ossl-modules, not to openssl's (OPENSSL_MODULES)
  patches = [ ./module-dir.patch ];
  dependencies = [ pkgs.openssl ];
  # the suite wants softhsm, kryoptic, NSS and certtool; tests/packages/pkcs11-provider signs
  # through it with softhsm instead
  tests.run = false;
  tests.version = false;
  bin = [ ];
  platforms.os = [ "linux" ];
}
