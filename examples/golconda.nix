# examples/golconda.nix — a working example that loads server.toml.
#
# Evaluates and builds from within the golconda repository:
#   iets eval -E '(import ./examples/golconda.nix).usrTree.outPath'
#   nix-build -E '(import ./examples/golconda.nix).usrTree'
#
# The result is the /usr tree: base packages, sshd from server.toml,
# and the image artifacts in /usr/lib/golconda/.
let
  # Import lib/system.nix from this repository.
  mkSystem = import ../lib/system.nix;
in
mkSystem {
  config = ./server.toml;
  # The build host, explicit so that `iets eval` stays pure: left out, `system` is
  # builtins.currentSystem, which needs `--impure`.
  system = "x86_64-linux";
  # platform defaults to the build host's.
  # extra can add Nix-only options.
}
