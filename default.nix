# Golconda: entry point for classic Nix and iets.
#   iets build -A packages.x86_64-linux.nix
#   nix-build -A checks.x86_64-linux.treefmt
# Inputs are pinned by npins (npins/sources.json). The output schema is the
# flake one, provided by flake-incompat; flake.nix is a thin wrapper.
let
  sources = import ./nix/sources.nix;
  flake-incompat = import sources.flake-incompat;
  system = import ./nix/system.nix;
in
flake-incompat.mkFlake {
  # nix/default.nix takes inputs by name: the pins as one set, and self
  inputs = {
    inherit sources;
    self = ./.;
  };
  expr = ./nix;
  systems = system.supported;
  # Per-system arguments. `platform` is the elaborated system (nix/system.nix),
  # `pkgs` the repkgs set for it (nix/packages.nix). No nixpkgs here.
  argsFun = double: {
    platform = system.elaborate double;
    pkgs = import ./nix/packages.nix {
      inherit sources;
      platform = double;
    };
  };
}
