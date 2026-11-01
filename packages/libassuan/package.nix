# IPC library of the GnuPG components: gpg talks to gpg-agent through it
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "libassuan";
  uses = [ "autotools" ];
  autotools.flags = [ "--disable-doc" ];
  buildDependencies = [ buildPkgs.libgpg-error ]; # configure runs gpgrt-config
  dependencies = [ pkgs.libgpg-error ];
  bin = [ ];
}
