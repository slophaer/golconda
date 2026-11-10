# lib/pins.nix: read a directory of pins in uptrack's format, purely, with no input of its own.
# pins/default.nix reads Golconda's inputs with it, and default.nix exports `read` as
# lib.readPins for a downstream repository's own pins.
#
# A pin is a directory <name>/ with a sources.toml. Its first [[source]] is the tarball; the url's
# {placeholders} are [pin] keys ({rev}, {version}), as uptrack expands them, and its hash is the
# NAR hash of the unpacked tree, which is fetchTarball's. A file beside the directories is skipped.
#
#   specs dir → { <name> = { url; sha256; }; }   the fetchTarball arguments
#   read dir  → { <name> = the unpacked tree; }
let
  inherit (builtins)
    attrNames
    attrValues
    fetchTarball
    filter
    fromTOML
    head
    listToAttrs
    mapAttrs
    readDir
    readFile
    replaceStrings
    ;
  spec =
    file:
    let
      t = fromTOML (readFile file);
      pin = t.pin or { };
      s = head t.source;
    in
    {
      url = replaceStrings (map (k: "{${k}}") (attrNames pin)) (map toString (attrValues pin)) s.url;
      sha256 = s.hash;
    };
  specs =
    dir:
    let
      entries = readDir dir;
    in
    listToAttrs (
      map (name: {
        inherit name;
        value = spec (dir + "/${name}/sources.toml");
      }) (filter (n: entries.${n} == "directory") (attrNames entries))
    );
in
{
  inherit specs;
  read = dir: mapAttrs (_: fetchTarball) (specs dir);
}
