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
in
[
  (check "pins: read gives the same trees for pins/ as pins/default.nix" (
    outPaths (pins.read ../../pins) == outPaths sources
    && attrNames sources == attrNames (pins.specs ../../pins)
  ))
  (check "pins: lib.readPins is the reader" (
    outPaths (f.lib.readPins ../../pins) == outPaths sources
  ))
]
