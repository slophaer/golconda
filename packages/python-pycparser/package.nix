# pycparser: a C parser in Python, which cffi parses its declarations with. A development tool's
# library (virt-firmware, scripts/boot-test), not part of an image
{
  package,
  buildPkgs,
}:
package {
  name = "python-pycparser";
  uses = [ "python" ];
  python.module = "pycparser";
  buildDependencies = [ buildPkgs.python-setuptools ];
}
