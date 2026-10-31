# The pins, read from npins/sources.json without npins' generated default.nix:
# that file reads NPINS_OVERRIDE_* from the environment, which the strict iets
# lint refuses, and these ten lines are all Golconda needs. `npins` still
# manages the JSON.
#
# Any pin type with `url` and `hash` works (Git, GitHub, Forgejo, Channel,
# Tarball). npins always produces these two fields for fetchable pins.
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
      throw "golconda: pin '${name}' has no url and hash";
in
builtins.mapAttrs fetch json.pins
