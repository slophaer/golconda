# golconda.nix — template for a Golconda system configuration.
#
# Copy this file next to your server.toml and edit the paths below.
#
# Usage:
#   iets eval -E '(import ./golconda.nix).usrTree.outPath'
#   nix-build -E '(import ./golconda.nix).usrTree'
#
# The result is the /usr tree: units, files, packages and symlinks,
# ready for the image builder.
#
# `config` is a TOML file (like server.toml) validated against the schema.
# `extra` is for Nix-only values: package overrides, custom fragments.
#
# See docs/reference/config.md for the full surface.
let
  # Pin Golconda with npins (`npins add git <golconda url>`) or point at a checkout.
  golconda = import (import ./npins).golconda;
in
golconda.lib.mkSystem {
  config = ./server.toml;
  # The build host, explicit so that `iets eval` stays pure: left out, `system` is
  # builtins.currentSystem, which needs `--impure`.
  system = "x86_64-linux";
  # platform = "aarch64-linux";  # default: the build host's
  # extra = {                   # Nix-only options, merged into the TOML
  #   "/services/sshd".package = myOpenSSH;
  # };
}
