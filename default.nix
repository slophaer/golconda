# Golconda: entry point for classic Nix and iets.
#   iets build -A packages.x86_64-linux.nix
#   nix-build -A checks.x86_64-linux.treefmt
# Inputs are pinned by npins (npins/sources.json). The output schema is the
# flake one, provided by flake-incompat; flake.nix is a thin wrapper.
let
  sources = import ./nix/sources.nix;
  flake-incompat = import sources.flake-incompat;
in
flake-incompat.mkFlake {
  # nix/default.nix takes inputs by name: the pins as one set, and self
  inputs = {
    inherit sources;
    self = ./.;
  };
  expr = ./nix;
  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];
  # Per-system arguments, from the repkgs set for the platform (nix/packages.nix): `pkgs` and
  # `platform`, repkgs' record (nix/platforms.nix). No nixpkgs here.
  argsFun =
    name:
    let
      set = import ./nix/packages.nix {
        inherit sources;
        platform = name;
      };
    in
    {
      inherit (set) pkgs platform;
    };
}
