# The flake-incompat expression. Each per-system field is a function of
# { pkgs, platform } (nix/system.nix, nix/packages.nix); the rest is plain.
{ sources, self }:
let
  dev = import ./dev { inherit sources; };
in
{
  packages =
    { pkgs }:
    {
      # the patched Nix daemon repkgs needs (CA + dynamic derivations); builders run it
      inherit (pkgs) nix;
    };

  checks =
    { platform }:
    import ./checks.nix {
      inherit sources self;
      inherit (platform) double;
    };

  # `iets fmt` / `nix fmt`: treefmt with every tool pinned (nix/dev/).
  formatter = { platform }: (dev platform.double).treefmt;

  devShells =
    { platform }:
    {
      default = (dev platform.double).shell;
    };

  lib = {
    system = import ./system.nix;
  };

  # The adios module tree (modules/). `modules { options = {...}; }` evaluates it.
  modules = import ../modules { inherit (import sources.adios) adios; };
}
