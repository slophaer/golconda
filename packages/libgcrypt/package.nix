# GnuPG's crypto library
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "libgcrypt";
  uses = [ "autotools" ];
  autotools.flags = [ "--disable-doc" ];
  buildDependencies = [ buildPkgs.libgpg-error ]; # configure runs gpgrt-config
  dependencies = [ pkgs.libgpg-error ];
  bin = [
    "dumpsexp"
    "hmac256"
    "mpicalc"
  ];
}
