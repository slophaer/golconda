# Render an attrset of sections to systemd-style INI text. A list value
# repeats the key; booleans become yes/no; null drops the key.
let
  inherit (builtins)
    concatStringsSep
    attrNames
    isList
    isBool
    ;
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
    "[${name}]\n" + concatStringsSep "\n" (builtins.concatMap (k: line k kv.${k}) (attrNames kv));
in
{
  render =
    sections: concatStringsSep "\n\n" (map (n: section n sections.${n}) (attrNames sections)) + "\n";
}
