# The union of fragments, the one rule the composer (/system) and modules that
# return more than one fragment share: attribute fields (units, files) must
# not repeat a key, list fields concatenate. There is no priority and no
# override; a key defined twice throws with its name (docs/design/modules.md).
#
#   merge [ fragmentA fragmentB ] -> fragment
let
  inherit (builtins)
    attrNames
    concatLists
    filter
    foldl'
    ;

  unionNoDup =
    field: fragments:
    foldl' (
      acc: f:
      let
        new = f.${field} or { };
        dup = filter (k: acc ? ${k}) (attrNames new);
      in
      if dup != [ ] then throw "golconda: ${field} defined twice: ${toString dup}" else acc // new
    ) { } fragments;

  concat = field: fragments: concatLists (map (f: f.${field} or [ ]) fragments);
in
fragments: {
  units = unionNoDup "units" fragments;
  files = unionNoDup "files" fragments;
  sysusers = concat "sysusers" fragments;
  tmpfiles = concat "tmpfiles" fragments;
  packages = concat "packages" fragments;
}
