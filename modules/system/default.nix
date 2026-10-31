# The composer: takes fragments, returns one system. Union with an error on a
# duplicate key; there is no priority system (docs/design/modules.md). The
# union itself is modules/lib/merge.nix, so a module that returns several
# fragments applies the same rule. Output: { name; version; units; files;
# sysusers; tmpfiles; packages }, every file as { text; mode; }.
{ types, ... }:
let
  fragmentT = (import ../lib/fragment.nix { inherit types; }).fragment;
  merge = import ../lib/merge.nix;
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
    merge options.fragments
    // {
      inherit (options) name version;
    };
}
