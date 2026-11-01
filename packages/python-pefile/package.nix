# pefile: PE parsing module for ukify (systemd UEFI tools)
{
  package,
  buildPkgs,
}:
package {
  name = "python-pefile";
  uses = [ "python" ];
  python.module = "pefile";
  buildDependencies = [ buildPkgs.python-setuptools ];
}
