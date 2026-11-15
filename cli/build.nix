# The expression `golconda release build` evaluates (cli/src/release.rs): Golconda's mkImage on the
# document, its unsigned outputs. Golconda is the tree `golconda` names (a checkout), or the tree of
# the uptrack pin `pin` (pins/golconda/sources.toml beside the document, docs/reference/pinning.md).
# The key sets are strings: mkImage copies their three public halves into the store, each file
# alone, and nothing else of them.
{
  golconda ? null,
  pin ? null,
  config,
  keys,
  pcrKeys,
  indexKeys,
  system,
}:
let
  # lib/pins.nix for one pin: the first [[source]]'s url with its {placeholders} filled from
  # [pin], and the NAR hash of the unpacked tree. Golconda is not there yet to read it.
  fetchPin =
    file:
    let
      t = builtins.fromTOML (builtins.readFile file);
      p = t.pin or { };
      s = builtins.head t.source;
    in
    builtins.fetchTarball {
      url = builtins.replaceStrings (map (k: "{${k}}") (builtins.attrNames p)) (map toString (
        builtins.attrValues p
      )) s.url;
      sha256 = s.hash;
    };
  tree = if pin != null then fetchPin pin else golconda;
in
((import tree).lib.mkImage {
  inherit config system;
  publicKeys = keys;
  pcrPublicKeys = pcrKeys;
  indexPublicKeys = indexKeys;
}).unsigned
