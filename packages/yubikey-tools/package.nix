# What a release host needs to sign with keys on a YubiKey, on one PATH: pcscd (with the USB reader
# driver ccid), yubico-piv-tool, and ykcs11-module, which prints the path of libykcs11.so for
# `golconda release build --pkcs11-module`. A tool of the release host, never in the image (the
# image has no smart card code). Each bin/ entry is a script that runs the tool of the same name
# from a dependency: a launcher (repkgs) puts the dependencies' bin/ on its PATH and gives it their
# exported environment, PCSCLITE_HP_DROPDIR from ccid and YKCS11_MODULE from yubico-piv-tool.
# docs/reference/release.md, "A YubiKey".
{ package, pkgs }:
package {
  name = "yubikey-tools";
  version = "1";
  source = ./.;
  install = {
    "bin/pcscd" = "bin/pcscd";
    "bin/yubico-piv-tool" = "bin/yubico-piv-tool";
    "bin/ykcs11-module" = "bin/ykcs11-module";
  };
  dependencies = [
    pkgs.pcsc-lite
    pkgs.ccid
    pkgs.yubico-piv-tool
  ];
  tests.version = false; # three scripts; tests/packages/yubikey-tools runs them
  platforms.os = [ "linux" ];
}
