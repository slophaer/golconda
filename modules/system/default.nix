#! The composer: takes fragments, returns one system.
#!
#! Union with an error on a duplicate key; there is no priority system
#! (see `docs/design/modules.md`). The union itself is `modules/lib/merge.nix`,
#! so a module that returns several fragments applies the same rule.
#!
#! The `/base`, `/network` and `/security` modules are always included first,
#! before any fragment the configuration declares. A system with no fragments
#! still has systemd, dbus-broker, dash, coreutils and the kernel.
#!
#! Output: `{ name; version; units; files; sysusers; tmpfiles; packages; packageOrigins; origins; links }`,
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
#! `"/network"`, `"/security"`, a fragment's own `name` (a module sets its path), or
#! `"fragments[<i>]"`. `packages` stays one deduped list.
#!
#! `origins` does the same for everything a fragment emits: `{ packages; files;
#! links; units; sysusers; tmpfiles; }`, each a map from the key (package key,
#! path under `/usr`, unit name, line) to the origins that emitted it.
#! `packageOrigins` is an alias of `origins.packages`. `lib/usr-tree.nix`
#! writes the maps to `/usr/lib/golconda/attribution.json`.
{ types, ... }:
let
  ini = import ../lib/ini.nix;
  versionLib = import ../../lib/version.nix { };
  # /system.updateSource -> /usr/lib/sysupdate.d/*.transfer (image/sysupdate.nix), and the
  # timer that runs them. systemd 257 named the suffix .transfer (.conf still loads, with a
  # warning). systemd 262 renamed systemd-sysupdate.timer to systemd-sysupdate-update.timer
  # and keeps the old name as an alias; the static .wants link enables it without presets
  # (docs/design/layout.md).
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
              name = "/usr/lib/sysupdate.d/${n}.transfer";
              value = {
                text = ini.render defs.${n};
                mode = "0644";
              };
            }) (builtins.attrNames defs)
          );
          links."/usr/lib/systemd/system/timers.target.wants/systemd-sysupdate-update.timer" = {
            target = "../systemd-sysupdate-update.timer";
            kind = "explicit";
          };
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

  # Version format: YYYYMMDD.N (a real calendar date plus a revision within the day).
  # strverscmp orders these correctly; lib/version.nix is the one grammar, and
  # lib/usr-tree.nix versionToEpoch derives the erofs timestamp from it.
  version = types.typedef' "version" (
    v: if !isString v then "Expected a string" else versionLib.error v
  );
in
{
  name = "system";

  # Implicit modules: every system has them, merged first.
  # /base: systemd, dbus-broker, dash, coreutils, kernel
  # /network: networkd configuration
  # /security: sysctl hardening (Yama, kptr_restrict, etc.)
  inputs = {
    base.path = "/base";
    network.path = "/network";
    security.path = "/security";
  };

  types = {
    fragment = fragmentT;
  };

  options = {
    name = {
      type = types.typedef' "imageName" (
        v:
        if !isString v then
          "Expected a string"
        else if match "[A-Za-z0-9][A-Za-z0-9._-]*" v == null then
          "'${v}' is not an image id: use letters, digits and _ . - and start with a letter or digit"
        else
          null
      );
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
    # /base, /network and /security fragments first, then the declared fragments
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
        {
          origin = "/security";
          fragment = results.security;
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
