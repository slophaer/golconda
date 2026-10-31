# golconda.nix — template for a Golconda system configuration.
#
# Copy this file next to your server.toml and edit the paths below.
#
# Usage:
#   nix-build ./golconda.nix -A usrTree
#   iets eval -E '(import ./golconda.nix).usrTree.outPath'
#
# The result is the /usr tree: units, files, packages and symlinks,
# ready for the image builder.
#
# `config` is a TOML file (like server.toml) validated against the schema.
# `extra` is for Nix-only values: package overrides, custom fragments.
#
# See docs/reference/config.md for the full surface.
import <golconda> {
  config = ./server.toml;
  # platform = "x86_64-linux";  # default: the build host's
  # extra = {                   # Nix-only options, merged into the TOML
  #   "/services/sshd".package = myOpenSSH;
  # };
}
