#! The composer: takes fragments, returns one system.
#!
#! Union with an error on a duplicate key; there is no priority system
#! (see `docs/design/modules.md`). The union itself is `modules/lib/merge.nix`,
#! so a module that returns several fragments applies the same rule.
#!
#! The `/base` module is always included first, before any fragment the
#! configuration declares. A system with no fragments still has systemd,
#! dbus-broker, dash, coreutils and the kernel.
#!
#! Output: `{ name; version; units; files; sysusers; tmpfiles; packages; packageOrigins; links }`,
#! every file as `{ text; mode; }` and `links` one map, path under `/usr` ->
#! `{ target; kind; }`: the `/usr/bin` links of the packages' `bin` lists and
#! the fragments' own links (`.wants`, directories to expand, dlopen sonames),
#! with one duplicate check that names both sources of a path. `units` holds
#! the system manager's units (typed names, `/usr/lib/systemd/system/<name>`);
#! a user unit (`service.scope = "user"`) is a file under
#! `/usr/lib/systemd/user/`, so one duplicate check covers both scopes.
#!
#! `packageOrigins` answers "why is this package here": package key (its
#! name-version) -> the origins that brought it, `"/base"`,
#! `"/network"`, a fragment's own `name` (a module sets its path), or
#! `"fragments[<i>]"`. `packages` stays one deduped list.
{ types, ... }:
let
  ini = import ../lib/ini.nix;
  # /system.updateSource -> /usr/lib/sysupdate.d/*.conf (image/sysupdate.nix)
  sysupdateFragment =
    options:
    if options.updateSource == null then
      [ ]
    else
      let
        defs = import ../../image/sysupdate.nix {
          imageId = options.name;
          inherit (options) updateSource;
        };
      in
      [
        {
          files = builtins.listToAttrs (
            map (n: {
              name = "/usr/lib/sysupdate.d/${n}.conf";
              value = {
                text = ini.render defs.${n};
                mode = "0644";
              };
            }) (builtins.attrNames defs)
          );
        }
      ];
  inherit (builtins)
    elemAt
    genList
    isString
    length
    match
    ;
  fragmentT = (import ../lib/fragment.nix { inherit types; }).fragment;
  merge = import ../lib/merge.nix;

  # Version format: YYYYMMDD.N (date plus revision within the day).
  # strverscmp orders these correctly; versionToEpoch in lib/usr-tree.nix
  # derives the erofs timestamp from this format.
  version = types.typedef' "version" (
    v:
    if !isString v then
      "Expected a string"
    else if match "[0-9]{8}\\.[0-9]+" v == null then
      "'${v}' is not a version: YYYYMMDD.N, such as 20261031.1"
    else
      null
  );
in
{
  name = "system";

  # /base is implicit: every system has it, merged first.
  inputs.base.path = "/base";
  # /network is implicit: its files are always merged.
  inputs.network.path = "/network";

  types = {
    fragment = fragmentT;
  };

  options = {
    name = {
      type = types.string;
      description = "Image id, the ID= of os-release and the UKI file name stem.";
    };
    version = {
      type = version;
      description = "Image version (YYYYMMDD.N). Each release must sort higher than the previous; systemd-sysupdate compares with strverscmp.";
    };
    updateSource = {
      type = types.option types.string;
      default = null;
      description = "URL of the update server. Rendered into /usr/lib/sysupdate.d/. When null (default), no sysupdate transfer is configured.";
    };
    fragments = {
      type = types.listOf fragmentT;
      default = [ ];
      description = "Fragments to merge. Each module returns a fragment; the composer unions them, erroring on duplicate keys.";
    };
  };

  impl =
    { options, results }:
    # /base and /network fragments first, then the declared fragments
    merge.withOrigins (
      [
        {
          origin = "/base";
          fragment = results.base;
        }
        {
          origin = "/network";
          fragment = results.network;
        }
      ]
      ++ genList (i: {
        origin = (elemAt options.fragments i).name or "fragments[${toString i}]";
        fragment = elemAt options.fragments i;
      }) (length options.fragments)
      ++ map (fragment: {
        origin = "/system";
        inherit fragment;
      }) (sysupdateFragment options)
    )
    // {
      inherit (options) name version updateSource;
    };
}
