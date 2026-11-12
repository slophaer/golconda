# cffi: Python's C foreign function interface, on libffi. cryptography's OpenSSL bindings are cffi
# code. A development tool's library (virt-firmware, scripts/boot-test), not part of an image
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "python-cffi";
  uses = [ "python" ];
  python.module = "cffi";
  buildDependencies = [
    buildPkgs.python-setuptools
    buildPkgs.pkgconf
  ];
  dependencies = [
    pkgs.libffi
    pkgs.python-pycparser
  ];
}
