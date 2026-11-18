# The expression `golconda release build` evaluates (cli/src/release.rs): Golconda's mkImage on the
# document, its unsigned outputs. Golconda is the tree of the uptrack pin `pin`
# (pins/golconda/sources.toml beside the document), or of the input `golconda` of the flake.lock
# `lock` beside it, or the tree `golconda` names (a checkout); docs/reference/pinning.md.
# The key sets are strings: mkImage copies their three public halves into the store, each file
# alone, and nothing else of them.
{
  golconda ? null,
  pin ? null,
  lock ? null,
  config,
  keys,
  pcrKeys,
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
  # the locked node of the root's input `golconda`, fetched as Nix fetches it for the flake
  fetchLock =
    file:
    let
      l = builtins.fromJSON (builtins.readFile file);
    in
    (builtins.fetchTree (removeAttrs l.nodes.${l.nodes.root.inputs.golconda}.locked [ "dir" ])).outPath;
  tree =
    if pin != null then
      fetchPin pin
    else if lock != null then
      fetchLock lock
    else
      golconda;
in
((import tree).lib.mkImage {
  inherit config system;
  publicKeys = keys;
  pcrPublicKeys = pcrKeys;
}).unsigned
