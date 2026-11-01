# The dev shell for a bare `nix-shell` and for direnv's `use nix` (.envrc).
# default.nix returns the flake schema, which holds no derivation at the top, so
# classic nix-shell needs this file to find devShells.<system>.default.
#
# `nix-shell -A <attr>` also reads this file once it exists, so it carries
# devShells too: `nix-shell -A devShells.x86_64-linux.default` keeps working.
{
  system ? builtins.currentSystem,
}:
let
  flake = import ./default.nix;
in
flake.devShells.${system}.default // { inherit (flake) devShells; }
