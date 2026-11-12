# cryptography: X.509 and the other primitives for Python, Rust (pyo3) on OpenSSL, built with
# maturin. virt-firmware reads the Secure Boot certificates with it. A development tool's library
# (scripts/boot-test), not part of an image. Its build script runs cffi to write the OpenSSL
# bindings' C code, so cffi is needed at build time as well as at run time
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "python-cryptography";
  uses = [
    "python"
    "cargo"
  ];
  python.backend = "maturin";
  python.module = "cryptography.x509";
  phases = [
    "python.build"
    "python.install"
    "python.test"
  ];
  buildDependencies = [
    buildPkgs.maturin
    buildPkgs.python-setuptools
    buildPkgs.pkgconf
  ];
  dependencies = [
    pkgs.openssl
    pkgs.python-cffi
  ];
}
