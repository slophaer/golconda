# examples/golconda.nix — the template for a Golconda system configuration, and a working example.
#
# Copy it, with server.toml and pins/golconda/sources.toml, into your own repository
# (docs/reference/pinning.md). It fetches Golconda from that pin and builds server.toml.
#
# Usage, in your repository:
#   iets eval -E '(import ./golconda.nix { }).usrTree.outPath'
#   nix-build golconda.nix -A usrTree
# In this repository, pass this tree in place of the pin:
#   iets eval -E '(import ./examples/golconda.nix { golconda = import ./default.nix; }).usrTree.outPath'
#
# The result is the /usr tree: units, files, packages and symlinks. `lib.mkImage` takes the
# same `config` and signs it into an image (docs/reference/outputs.md).
#
# `config` is a TOML file (like server.toml) validated against the schema.
# server.toml is the whole configuration. Your own units and files are a module in modules/
# beside it (mounted under /local), your own packages are in packages/ beside it
# (docs/reference/config.md).
#
# The pin is in uptrack's format; `uptrack check` says when Golconda moved, `uptrack apply`
# writes the new rev and hash. The reader below is what lib.readPins does for one pin: the first
# [[source]]'s url with its {placeholders} filled from [pin], and the NAR hash of the tree.
# Your other inputs can sit beside it in pins/: `golconda.lib.readPins ./pins` gives
# { golconda = …; <name> = the unpacked tree; }.
let
  fetchPin =
    file:
    let
      t = builtins.fromTOML (builtins.readFile file);
      pin = t.pin or { };
      src = builtins.head t.source;
      fill = builtins.replaceStrings (map (k: "{${k}}") (builtins.attrNames pin)) (
        map toString (builtins.attrValues pin)
      );
    in
    builtins.fetchTarball {
      url = fill src.url;
      sha256 = src.hash;
    };
in
{
  golconda ? import (fetchPin ./pins/golconda/sources.toml),
}:
golconda.lib.mkSystem {
  config = ./server.toml;
  # The build host, explicit so that evaluation stays pure (iets eval, a flake): left out,
  # `system` is builtins.currentSystem, which needs `--impure`.
  system = "x86_64-linux";
  # platform = "aarch64-linux";  # default: the build host's
}
