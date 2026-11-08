# Golconda: entry point for classic Nix and iets.
#   iets build -A packages.x86_64-linux.nix
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
  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];
  # Per-system arguments, from the repkgs set for the platform (nix/packages.nix): `pkgs`,
  # `platform` (repkgs' record, nix/platforms.nix), and `set` (the full repkgs set, for
  # options."/pkgs".target). No nixpkgs here.
  #
  # The build host (`system`) is the flake system; the target (`platform`) defaults to the
  # same. Cross-compilation: nix/default.nix builds packages for other targets under the
  # build host's output tree (e.g., packages.x86_64-linux.usr-tree-smoke-aarch64).
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
      # `system` is the build host (the flake system), for nix/default.nix to build cross targets
      system = name;
    };
}
