#! The composer: takes fragments, returns one system.
#!
#! Union with an error on a duplicate key; there is no priority system
#! (see `docs/design/modules.md`). The union itself is `modules/lib/merge.nix`,
#! so a module that returns several fragments applies the same rule.
#!
#! It selects nothing itself: `mkSystem` (`lib/components.nix`) passes the
#! fragments of the selected components as `components`, the built-ins
#! (`/base`, `/network`, `/security`, `/factory`, `/vars`) first, then each
#! optional component the configuration has a table for. A system with no
#! table still has systemd, dbus-broker, dash, coreutils and the kernel.
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
#! name-version) -> the origins that brought it: a component's module path
#! (`"/base"`, `"/services/sshd"`), another fragment's own `name`, or
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
  grammar = import ../lib/grammar.nix;
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
    isString
    match
    ;
  fragmentT = (import ../lib/fragment.nix { inherit types; }).fragment;
  merge = import ../lib/merge.nix;

  # Version format: YYYYMMDD.N (a real calendar date plus a revision within the day).
  # strverscmp orders these correctly. The type accepts what grammar.version matches, the
  # pattern the schema exports; lib/version.nix, whose toEpoch derives the erofs timestamp,
  # gives the reason for a refusal, and nix/tests.nix checks that the two agree.
  version = types.typedef' "version" (
    v:
    if !isString v then
      "Expected a string"
    else if match grammar.version v != null then
      null
    else
      let
        reason = versionLib.error v;
      in
      if reason != null then reason else "'${v}' is not a version: YYYYMMDD.N, such as 20261031.1"
  );
in
{
  name = "system";

  types = {
    fragment = fragmentT;
  };

  options = {
    name = {
      type = types.typedef' "imageName" (
        v:
        if !isString v then
          "Expected a string"
        else if match grammar.imageName v == null then
          "'${v}' is not an image id: use letters, digits and _ . - and start with a letter or digit (the id is os-release ID=, the artifact file name stem and the sysupdate match pattern)"
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
      type = types.option (
        types.typedef' "updateSource" (
          source:
          if !isString source then
            "Expected a string"
          else if builtins.length (builtins.split "[[:space:][:cntrl:]]" source) > 1 then
            "updateSource must not contain whitespace or a control character: it is a sysupdate Path= value"
          else if builtins.substring 0 1 source == "/" || match ".*://.*" source != null then
            null
          else
            "updateSource must be a URL (https://…) or an absolute path"
        )
      );
      default = null;
      description = "URL or absolute path of the update server. Rendered into /usr/lib/sysupdate.d/. When null (default), no sysupdate transfer is configured.";
    };
    secureBoot = {
      type = types.bool;
      default = true;
      description = "Whether the host's firmware enforces Secure Boot with the image's db key. When false, the kernel carries the db certificate in its built-in keyring and checks the /usr signature itself; the firmware then checks nothing, so whoever can write the ESP can replace the UKI (docs/design/trust.md). For a host without Secure Boot, such as Hetzner Cloud.";
    };
    fragments = {
      type = types.listOf fragmentT;
      default = [ ];
      description = "Fragments to merge. Each module returns a fragment; the composer unions them, erroring on duplicate keys.";
    };
    components = {
      type = types.listOf fragmentT;
      default = [ ];
      description = "The fragments of the selected components, each named by its module path. mkSystem passes them (lib/components.nix); not configuration data, and the TOML loader refuses it.";
    };
  };

  impl =
    { options, ... }:
    # the selected components first, then the declared fragments
    merge.withOrigins (
      map (
        fragment:
        if fragment ? name then
          {
            origin = fragment.name;
            inherit fragment;
          }
        else
          throw "golconda: /system.components: a component fragment needs its module path as `name` (lib/components.nix sets it)"
      ) options.components
      ++ merge.labelFragments options.fragments
      ++ map (fragment: {
        origin = "/system";
        inherit fragment;
      }) (sysupdateFragment options)
    )
    // {
      inherit (options)
        name
        version
        updateSource
        secureBoot
        ;
    };
}
