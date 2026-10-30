# The union of fragments, the one rule the composer (/system) and modules that
# return more than one fragment share: attribute fields (units, files) must
# not repeat a key, list fields concatenate. There is no priority and no
# override; a key defined twice throws with its name (docs/design/modules.md).
# The packages are checked as well: the image builder links them into one
# /usr/bin, so two packages with the same executable name throw.
#
#   merge [ fragmentA fragmentB ] -> fragment
let
  inherit (builtins)
    attrNames
    concatLists
    deepSeq
    filter
    foldl'
    ;

  # repkgs packages carry `bin`, their executable names, at evaluation time.
  # A package listed by two fragments is one package (same name), not a clash.
  pkgName = p: p.name or "${p.pname}-${p.version}";

  farm =
    packages:
    let
      owners = foldl' (
        owners: p:
        foldl' (
          acc: b:
          if acc ? ${b} && acc.${b} != pkgName p then
            throw "golconda: /usr/bin name defined twice: ${b} (${acc.${b}}, ${pkgName p})"
          else
            acc // { ${b} = pkgName p; }
        ) owners (p.bin or [ ])
      ) { } packages;
    in
    # the list itself, once the check has run
    deepSeq owners packages;

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
  packages = farm (concat "packages" fragments);
}
