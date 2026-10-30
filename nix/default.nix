# The flake-incompat expression. Each per-system field is a function of
# { pkgs, platform } (nix/packages.nix); the rest is plain.
{ sources, self }:
let
  dev = import ./dev { inherit sources; };
in
{
  packages =
    { pkgs, set }:
    {
      # the patched Nix daemon repkgs needs (CA + dynamic derivations); builders run it
      inherit (pkgs) nix;

      # Smoke test for wrap: wraps jq with --version prepended.
      # Requires repkgs pin to include wrap support (branch wrap merged into golconda).
      # When the pin is updated: nix-build -A packages.x86_64-linux.wrap-smoke
    }
    // (
      if set ? wrap then
        {
          wrap-smoke = set.wrap {
            package = pkgs.jq;
            argv = [ "--version" ];
          };
        }
      else
        { }
    );

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
