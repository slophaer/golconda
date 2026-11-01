# X.509 and CMS library. GnuPG's configure insists on it even with gpgsm and dirmngr off
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "libksba";
  uses = [ "autotools" ];
  buildDependencies = [ buildPkgs.libgpg-error ]; # configure runs gpgrt-config
  dependencies = [ pkgs.libgpg-error ];
  bin = [ ]; # library only
}
