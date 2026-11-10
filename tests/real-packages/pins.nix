# Checks of the pin reader (lib/pins.nix) on Golconda's own pins: it fetches them, so it is here
# and not in tests/eval (which reads the fixtures' pins as data, tests/eval/pins.nix).
# A function of ./default.nix's harness; it returns a list of checks.
{
  check,
  f,
  sources,
  ...
}:
let
  inherit (builtins) attrNames mapAttrs;
  pins = import ../../lib/pins.nix;
  outPaths = mapAttrs (_: toString);

  # The "Plain fetchTarball" recipe of docs/reference/pinning.md, which includes
  # examples/fetch-tarball.nix as it is. The page has placeholders where a reader puts the rev
  # and the hash; the file runs here with the example pin's, and nothing else changed: its
  # `builtins.fetchTarball` is the real one, called with the placeholders filled in.
  pin = builtins.fromTOML (builtins.readFile ../../examples/pins/golconda/sources.toml);
  fillPlaceholders =
    args:
    assert args.sha256 == "<the NAR hash of the unpacked tree>";
    let
      url = builtins.replaceStrings [ "<rev>" ] [ pin.pin.rev ] args.url;
    in
    assert url == (pins.specs ../../examples/pins).golconda.url;
    builtins.fetchTarball {
      inherit url;
      sha256 = (builtins.head pin.source).hash;
    };
  recipe = builtins.scopedImport {
    builtins = builtins // {
      fetchTarball = fillPlaceholders;
    };
  } ../../examples/fetch-tarball.nix;
in
[
  (check "pins: read gives the same trees for pins/ as pins/default.nix" (
    outPaths (pins.read ../../pins) == outPaths sources
    && attrNames sources == attrNames (pins.specs ../../pins)
  ))
  (check "pins: lib.readPins is the reader" (
    outPaths (f.lib.readPins ../../pins) == outPaths sources
  ))
  (check "pinning: the fetchTarball recipe of the docs evaluates, and gives the uptrack recipe's tree"
    (
      recipe.platform.name == "x86_64-linux"
      && recipe.usrTree.outPath == (import ../../examples/golconda.nix { }).usrTree.outPath
    )
  )
]
