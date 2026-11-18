# Golconda: entry point for classic Nix and iets.
#   iets build -A packages.x86_64-linux.golconda-cli
#   nix-build -A checks.x86_64-linux.treefmt
# Inputs are pinned in pins/ (uptrack, scripts/pins). The output schema is the
# flake one, provided by flake-incompat; flake.nix is a thin wrapper.
let
  sources = import ./pins;
  flake-incompat = import sources.flake-incompat;
in
flake-incompat.mkFlake {
  # nix/default.nix takes inputs by name: the pins as one set, and self
  inputs = {
    inherit sources;
    self = ./.;
  };
  expr = ./nix;
  systems = [ "x86_64-linux" ];
  # Per-system arguments, from the repkgs set for the platform (nix/packages.nix): `pkgs`,
  # `platform` (repkgs' record, nix/platforms.nix), and `set` (the full repkgs set, for
  # nix/run.nix, the checks and the dev shell). No nixpkgs here.
  #
  # The build host (`system`) is the flake system; the target (`platform`) is the same.
  argsFun =
    name:
    let
      r = import ./nix/packages.nix {
        inherit sources;
        system = name;
        platform = name;
      };
    in
    {
      inherit (r) set pkgs platform;
      # `system` is the build host (the flake system)
      system = name;
    };
}
