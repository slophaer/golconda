# The Golconda module tree (adios). Paths are absolute from this root:
# "/system" is the composer; modules/lib holds shared types.
#
# `local` is a downstream repository's module directory, or null: its modules are
# mounted under /local (/local/<name>), so they can never take a Golconda module's path.
# mkSystem passes it from the configuration (lib/config.nix, `golconda.modules`).
{
  adios,
  local ? null,
}:
adios {
  name = "golconda";
  modules =
    adios.lib.importModules ./.
    // (
      if local == null then
        { }
      else
        {
          local = {
            name = "local";
            modules = adios.lib.importModules local;
          };
        }
    );
}
