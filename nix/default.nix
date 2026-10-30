# The flake-incompat expression. Each per-system field is a function of
# { pkgs, platform } (nix/packages.nix); the rest is plain.
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
      double = platform.name;
    };

  # `iets fmt` / `nix fmt`: treefmt with every tool pinned (nix/dev/).
  formatter = { platform }: (dev platform.name).treefmt;

  devShells =
    { platform }:
    {
      default = (dev platform.name).shell;
    };

  # The adios module tree (modules/). `modules { options = {...}; }` evaluates it.
  modules = import ../modules { inherit (import sources.adios) adios; };
}
