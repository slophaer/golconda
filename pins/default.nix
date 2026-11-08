# The inputs: pins/<name>/sources.toml, kept by uptrack (`scripts/pins`), read here purely.
# `import ./pins` gives { <name> = the unpacked tree; }. Each file's first [[source]] is the
# tarball; its url's {placeholders} are [pin] keys ({rev}, {version}), as uptrack expands them,
# and its hash is the NAR hash of the unpacked tree, which is fetchTarball's.
let
  inherit (builtins)
    attrNames
    attrValues
    filter
    fromTOML
    head
    listToAttrs
    readDir
    readFile
    replaceStrings
    ;
  dir = readDir ./.;
  names = filter (n: dir.${n} == "directory") (attrNames dir);
  fetch =
    name:
    let
      t = fromTOML (readFile (./. + "/${name}/sources.toml"));
      pin = t.pin or { };
      s = head t.source;
    in
    builtins.fetchTarball {
      url = replaceStrings (map (k: "{${k}}") (attrNames pin)) (map toString (attrValues pin)) s.url;
      sha256 = s.hash;
    };
in
listToAttrs (
  map (name: {
    inherit name;
    value = fetch name;
  }) names
)
