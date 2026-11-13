# the daemon the tool talks to, p11-kit that loads a PKCS#11 module and lists it, and openssl with
# pkcs11-provider, the way the signer loads one
pkgs: {
  inherit (pkgs)
    openssl
    p11-kit
    pkcs11-provider
    pcsc-lite
    ;
}
