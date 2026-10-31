#! The composer: takes fragments, returns one system.
#!
#! Union with an error on a duplicate key; there is no priority system
#! (see `docs/design/modules.md`). The union itself is `modules/lib/merge.nix`,
#! so a module that returns several fragments applies the same rule.
#!
#! Output: `{ name; version; units; files; sysusers; tmpfiles; packages; links }`,
#! every file as `{ text; mode; }` and `links` one map, path under `/usr` ->
#! `{ target; kind; }`: the `/usr/bin` links of the packages' `bin` lists and
#! the fragments' own links (`.wants`, directories to expand, dlopen sonames),
#! with one duplicate check that names both sources of a path. `units` holds
#! the system manager's units (typed names, `/usr/lib/systemd/system/<name>`);
#! a user unit (`service.scope = "user"`) is a file under
#! `/usr/lib/systemd/user/`, so one duplicate check covers both scopes.
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
      description = "Fragments to merge. Each module returns a fragment; the composer unions them, erroring on duplicate keys.";
    };
  };

  impl =
    { options }:
    merge options.fragments
    // {
      inherit (options) name version;
    };
}
