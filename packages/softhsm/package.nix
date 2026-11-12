# SoftHSM 2: a PKCS#11 token in software, with OpenSSL as its crypto backend. TEST-ONLY: the
# signer's tests put throwaway keys on it and sign a release through pkcs11-provider, as a
# release host signs with keys on a YubiKey (tests/sign, nix/default.nix image-smoke-test-pkcs11).
# Never a release host's token: its keys are files under its token directory.
{ package, pkgs }:
package {
  name = "softhsm";
  uses = [ "cmake" ];
  # Token.cpp needs <ctime>, which libc++ does not pull in through <cstdio>
  patches = [ ./ctime.patch ];
  cmake.defs = {
    WITH_CRYPTO_BACKEND = "openssl";
    ENABLE_P11_KIT = false; # no module file for p11-kit: callers name libsofthsm2.so
    ENABLE_STATIC = false;
    ENABLE_GOST = false;
    # install etc/softhsm2.conf.sample into the package; the compiled-in defaults stay the host's
    # (callers set SOFTHSM2_CONF to a configuration of their own, and give softhsm2-util the
    # module with --module: a path into the package would not be relocatable)
    CMAKE_INSTALL_SYSCONFDIR = "etc";
    CMAKE_INSTALL_LOCALSTATEDIR = "var";
    DEFAULT_SOFTHSM2_CONF = "/etc/softhsm2.conf";
    DEFAULT_TOKENDIR = "/var/lib/softhsm/tokens/";
    DEFAULT_PKCS11_LIB = "/usr/lib/softhsm/libsofthsm2.so";
  };
  # the empty token directory that install makes under var/: a token lives where its
  # configuration says
  phases.after."cmake.install" = {
    name = "drop-var";
    run = ''
      rm -rf $"($c.out)/var"
    '';
  };
  dependencies = [ pkgs.openssl ];
  tests.run = false; # the suite needs cppunit; tests/packages/softhsm makes a token instead
  bin = [ "softhsm2-util" ];
  tests.version = false; # --version runs no module; tests/packages/softhsm checks the version
  platforms.os = [ "linux" ];
}
