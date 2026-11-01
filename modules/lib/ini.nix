# Render an attrset of sections to systemd-style INI text. A list value
# repeats the key; booleans become yes/no; null drops the key.
#
# The renderer is the boundary between a typed value and the file text, so it
# is where a value that would change the file's structure is refused: a
# section name or a key is one plain word, and a string value
# holds no control character, because a line break would start a directive
# (or, in a section position, a new section). Callers keep raw text out of
# INI: a value that is meant to be several lines is a file of its own.
let
  inherit (builtins)
    concatStringsSep
    attrNames
    foldl'
    isList
    isBool
    isString
    length
    match
    split
    ;

  hasControl = s: length (split "[[:cntrl:]]" s) > 1;
  isWord = s: isString s && match "[A-Za-z0-9_.:-]+" s != null;

  checkValue =
    name: k: v:
    if isString v then
      if hasControl v then
        throw "golconda: ini: section '${name}', key '${k}': a value must not contain a line break or another control character (a line break would add a directive)"
      else
        true
    else if isList v then
      foldl' (
        _: x:
        if isString x && hasControl x then
          throw "golconda: ini: section '${name}', key '${k}': a list entry must not contain a line break or another control character (a line break would add a directive)"
        else
          true
      ) true v
    else
      true;

  # A section name and its keys are plain words; every value is one line.
  check =
    name: kv:
    if !isWord name then
      throw "golconda: ini: '${toString name}' is not a section name: use letters, digits and _ . : -"
    else
      foldl' (
        _: k:
        if !isWord k then
          throw "golconda: ini: section '${name}': '${toString k}' is not a key: use letters, digits and _ . : -"
        else
          checkValue name k kv.${k}
      ) true (attrNames kv);

  line =
    k: v:
    if v == null then
      [ ]
    else if isList v then
      map (x: "${k}=${toString x}") v
    else if isBool v then
      [ "${k}=${if v then "yes" else "no"}" ]
    else
      [ "${k}=${toString v}" ];
  section =
    name: kv:
    assert check name kv;
    "[${name}]\n" + concatStringsSep "\n" (builtins.concatMap (k: line k kv.${k}) (attrNames kv));
in
{
  render =
    sections: concatStringsSep "\n\n" (map (n: section n sections.${n}) (attrNames sections)) + "\n";
}
