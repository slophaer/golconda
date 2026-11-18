# examples/golconda.nix — the template for a Golconda system configuration, and a working example.
# Copy it, with server.toml and pins/golconda/sources.toml, into your own repository: it fetches
# Golconda from that pin and builds server.toml (docs/reference/pinning.md).
#   iets eval -E '(import ./golconda.nix { }).usrTree.outPath'
#   nix-build golconda.nix -A usrTree
# In this repository, pass this tree in place of the pin:
#   iets eval -E '(import ./examples/golconda.nix { golconda = import ./default.nix; }).usrTree.outPath'
# server.toml is the whole configuration; your own modules and packages sit beside it in modules/
# and packages/ (docs/reference/config.md). `golconda release build` signs the image
# (docs/reference/release.md). The reader below is what lib.readPins does for one pin: the first
# [[source]]'s url with its {placeholders} filled from [pin], and the NAR hash of the tree.
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
  # platform = "x86_64-linux";  # the target; default: the build host's
}
