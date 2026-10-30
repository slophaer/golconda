# The composer: takes fragments, returns one system. Union with an error on a
# duplicate key; there is no priority system (docs/design/modules.md).
{ types, ... }:
let
  fragmentT = import ../lib/fragment.nix { inherit types; };
in
{
  name = "system";

  types = {
    fragment = fragmentT;
  };

  options = {
    name = {
      type = types.string;
      description = "Image id, the ID= of os-release and the UKI file name stem.";
    };
    version = {
      type = types.string;
      description = "Image version; must sort higher than the previous one (systemd-sysupdate compares versions).";
    };
    fragments = {
      type = types.listOf fragmentT;
      default = [ ];
    };
  };

  impl =
    { options }:
    let
      inherit (builtins) foldl' attrNames concatLists;
      checked = options.fragments;

      unionNoDup =
        field:
        foldl' (
          acc: f:
          let
            new = f.${field} or { };
            dup = builtins.filter (k: acc ? ${k}) (attrNames new);
          in
          if dup != [ ] then throw "golconda: ${field} defined twice: ${toString dup}" else acc // new
        ) { } checked;

      concat = field: concatLists (map (f: f.${field} or [ ]) checked);
    in
    {
      inherit (options) name version;
      units = unionNoDup "units";
      files = unionNoDup "files";
      sysusers = concat "sysusers";
      tmpfiles = concat "tmpfiles";
      packages = concat "packages";
    };
}
