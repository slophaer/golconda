# The Golconda module tree (adios). Paths are absolute from this root:
# "/system" is the composer; modules/lib holds shared types.
{ adios }:
adios {
  name = "golconda";
  modules = adios.lib.importModules ./.;
}
