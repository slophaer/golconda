# Yubico's PIV tools: yubico-piv-tool (sets the PIN, PUK and management key, imports a key and its
# certificate into a PIV slot), libykpiv, and libykcs11.so, the YubiKey's PKCS#11 module that
# `golconda release build --pkcs11-module` loads. All three talk to the key through pcscd
# (packages/pcsc-lite). A tool of the release host, never in the image (packages/yubikey-tools).
{ package, pkgs }:
package {
  name = "yubico-piv-tool";
  uses = [ "cmake" ];
  # upstream adds its tests (check, and a YubiKey for most) to the build whether or not they run,
  # and fails to configure without the check library; it also runs gengetopt on every configure,
  # though the tarball has the cmdline.c and cmdline.h that it made
  patches = [ ./build-fixes.patch ];
  cmake.defs = {
    CMAKE_BUILD_TYPE = "Release"; # upstream defaults to Debug
    BUILD_STATIC_LIB = false;
    GENERATE_MAN_PAGES = false; # help2man; the tarball's pre-built page is installed
    ENABLE_HARDWARE_TESTS = false; # they ERASE every YubiKey that is plugged in
    BACKEND = "pcsc";
  };
  dependencies = [
    pkgs.openssl
    pkgs.pcsc-lite
    pkgs.zlib
  ];
  # the suite wants `check` and, for most of it, a YubiKey; tests/packages/yubico-piv-tool loads
  # the module and runs the tool with no key instead
  tests.run = false;
  bin = [ "yubico-piv-tool" ];
  exports.env.YKCS11_MODULE = "{root}/lib/libykcs11.so";
  platforms.os = [ "linux" ];
}
