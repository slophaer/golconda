# pyelftools: ELF/DWARF analysis library for systemd's bootloader stub
{
  package,
  buildPkgs,
}:
package {
  name = "python-pyelftools";
  uses = [ "python" ];
  python.module = "elftools";
  buildDependencies = [ buildPkgs.python-setuptools ];
}
