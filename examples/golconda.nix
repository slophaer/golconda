# examples/golconda.nix — the template for a Golconda system configuration, and a working example.
#
# It loads the server.toml next to it. To use it for your own system, copy it next to your
# server.toml and replace the `golconda` line as the comment says.
#
# Usage:
#   iets eval -E '(import ./examples/golconda.nix).usrTree.outPath'
#   nix-build -E '(import ./examples/golconda.nix).usrTree'
#
# The result is the /usr tree: units, files, packages and symlinks. `lib.mkImage` takes the
# same `config` and signs it into an image (docs/reference/outputs.md).
#
# `config` is a TOML file (like server.toml) validated against the schema.
# server.toml is the whole configuration. Your own units and files are a module in modules/
# beside it (mounted under /local), your own packages are in packages/ beside it
# (docs/reference/config.md). With no build-host argument, `golconda.lib.mkSystem ./server.toml`.
#
# See docs/reference/config.md for the full surface.
let
  # In your own repository, pin Golconda with npins (`npins add git <golconda url> --name
  # golconda`) and use: golconda = import (import ./npins).golconda;
  golconda = import ../default.nix;
in
golconda.lib.mkSystem {
  config = ./server.toml;
  # The build host, explicit so that `iets eval` stays pure: left out, `system` is
  # builtins.currentSystem, which needs `--impure`.
  system = "x86_64-linux";
  # platform = "aarch64-linux";  # default: the build host's
}
