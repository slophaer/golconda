# The pins, read from npins/sources.json without npins' generated default.nix:
# that file reads NPINS_OVERRIDE_* from the environment, which the strict iets
# lint refuses, and these ten lines are all Golconda needs. `npins` still
# manages the JSON.
let
  json = builtins.fromJSON (builtins.readFile ../npins/sources.json);
  fetch =
    name: pin:
    if pin ? url && pin ? hash then
      builtins.fetchTarball {
        inherit (pin) url;
        sha256 = pin.hash;
      }
    else
      throw "golconda: pin '${name}' has no url and hash; only tarball pins are supported";
in
builtins.mapAttrs fetch json.pins
