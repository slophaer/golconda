# lib/system.nix: the entry point for one Golconda system.
#
# mkSystem { config; platform?; sources?; extra?; extraFragments?; } → {
#   composed;   # the composer output (units, files, links, packages, …)
#   usrTree;    # the /usr derivation
#   config;     # config.json: module path -> option -> { value?; explicit; }
#   platform;   # the elaborated platform record
#   version;    # YYYYMMDD.N from /system
#   name;       # image id from /system
#   pkgs;       # the packages for this platform
# }
#
# `config` is a path to a TOML file or an attrset already loaded.
# `platform` defaults to the build host's (builtins.currentSystem).
# `sources` defaults to ../nix/sources.nix.
# `extra` overrides individual options from the configuration.
# `extraFragments` adds image-owned fragments after those overrides, before composition.
# `verityCert` is the certificate that signs /usr (lib.mkImage passes the db certificate of
# its keys). With `/system.secureBoot = false` the kernel carries it in its built-in keyring;
# without Secure Boot nothing else would put it in a keyring (docs/design/trust.md).
#
# Usage:
#   let sys = import ./lib/system.nix { config = ./server.toml; };
#   in sys.usrTree
#
# Nix-only values (a package override, a fragment written in Nix) come through
# `extra`, so a configuration can be pure TOML or TOML + Nix.
{
  config,
  platform ? system,
  system ? builtins.currentSystem,
  sources ? import ../nix/sources.nix,
  extra ? { },
  extraFragments ? [ ],
  verityCert ? null,
}:
let
  inherit (builtins)
    attrNames
    isAttrs
    isPath
    mapAttrs
    ;

  adios = import sources.adios;
  tree = import ../modules { inherit (adios) adios; };
  unloaded = tree { };
  treeLib = import ./tree.nix { };

  # Load the repkgs set for this platform. The kernel config depends on /system.secureBoot,
  # read from the options before the tree checks them: the tree needs the set, and the
  # option's type still checks the value when /system is evaluated.
  secureBoot = ((mergeModuleOptions loadedOptions extra)."/system" or { }).secureBoot or true;
  setFull = import ../nix/packages.nix {
    inherit sources system platform;
    kernelConfig =
      if secureBoot != false then
        { }
      else
        {
          SYSTEM_TRUSTED_KEYS =
            if verityCert == null then
              throw "golconda: /system.secureBoot = false needs the image's keys: the kernel carries the db certificate, so build it with lib.mkImage"
            else
              "${verityCert}";
        };
  };

  # The TOML loader: a document in, checked options out (lib/config.nix).
  configLib = import ./config.nix { tree = unloaded; };

  # Load configuration: a path is TOML, an attrset is already loaded options.
  loadedOptions =
    if isPath config then
      (configLib.loadConfig config).options
    else if isAttrs config then
      config
    else
      throw "golconda: config must be a path to a TOML file or an attrset of options";

  # Merge option names at each module path; nested values replace rather than recurse.
  # extra."/system".name overrides just that field, not the whole /system entry.
  mergeModuleOptions =
    a: b:
    builtins.mapAttrs (k: av: if b ? ${k} && isAttrs av && isAttrs b.${k} then av // b.${k} else av) a
    // builtins.removeAttrs b (attrNames a);

  # A table names a module, and an option name must be one the module
  # declares (configLib.checkOptions). The loader checked the TOML; this
  # checks what an attrset config and `extra` give, so every route into the
  # tree is checked. mkSystem is the one place that binds /pkgs.target: it is
  # always the platform's set, never from the document or `extra`.
  mergedOptions = configLib.checkOptions (mergeModuleOptions loadedOptions extra) // {
    "/pkgs".target = setFull.set;
  };

  # Evaluate the module tree with the merged options.
  evaluated = tree { options = mergedOptions; };

  # Gather fragments from service modules that have options set in the config.
  # A service is enabled when its path appears in the config (e.g., /services/sshd).
  # Implicit modules (/vars, /factory, /network) are always included.
  configuredServices = builtins.filter (p: builtins.match "/services/.*" p != null) (
    attrNames mergedOptions
  );

  # "/services/sshd" -> evaluated.modules.services.modules.sshd, called
  serviceFragments = map (path: treeLib.moduleAt evaluated path { }) configuredServices;

  varsFragment = evaluated.modules.vars { };

  # /usr/lib/udev/hwdb.bin, compiled at build time by the build host's systemd-hwdb from the
  # target's sources (lib/image/hwdb.nix): the image has no writable place for it before udev runs
  imageLib = import ./image { };
  hwdbFragment = imageLib.hwdbFragment {
    hwdb = imageLib.hwdb {
      buildSystem = system;
      tool = setFull.set.buildPkgs.systemd;
      inherit (setFull.pkgs) systemd;
    };
  };
  factoryFragment = evaluated.modules.factory { };

  # The system options from the config (name, version, fragments, updateSource).
  systemOptions = mergedOptions."/system" or { };

  # The composed system: /system with all fragments.
  composedRaw =
    (tree {
      options = mergedOptions // {
        "/system" = systemOptions // {
          fragments =
            (systemOptions.fragments or [ ])
            ++ extraFragments
            ++ serviceFragments
            ++ [
              varsFragment
              factoryFragment
              hwdbFragment
            ];
        };
      };
    }).modules.system
      { };

  # Reading the name forces the option types, including the image-id and transfer-path rules.
  composed = builtins.seq composedRaw.name composedRaw;

  # The schema for this tree.
  schemaLib = import ./schema.nix { };
  moduleFiles = treeLib.modulePaths ../modules;
  schema = schemaLib.toJsonSchemaWith {
    files = moduleFiles;
    root = toString ../.;
  } unloaded;

  # The normalized configuration: one row per option of every configured module,
  # { value?; explicit; }, for config.json. `explicit` is true when the TOML (or `extra`)
  # set the option, false when the default applies; an option with a computed default
  # (defaultFunc) has no `value` then. Derivations render as their name, so the JSON is data.
  normalizedConfig =
    let
      stripDerivations =
        v:
        if isAttrs v then
          if v ? outPath then
            # A derivation: record its name only
            v.name or v.pname or "<derivation>"
          else
            mapAttrs (_: stripDerivations) v
        else if builtins.isList v then
          map stripDerivations v
        else
          v;

      rows =
        path: given:
        let
          declared = (treeLib.moduleAt unloaded path).options or { };
        in
        mapAttrs (
          n: _:
          if given ? ${n} then
            {
              value = stripDerivations given.${n};
              explicit = true;
            }
          else if declared.${n} ? default && schemaLib.isPlainData declared.${n}.default then
            {
              value = declared.${n}.default;
              explicit = false;
            }
          else
            { explicit = false; }
        ) (declared // given);
    in
    builtins.listToAttrs (
      map
        (path: {
          name = path;
          value = rows path mergedOptions.${path};
        })
        (
          # /pkgs: its set is not configuration data
          builtins.filter (p: p != "/pkgs") (attrNames mergedOptions)
        )
    );

  # usr-tree library for building the tree.
  usrTreeLib = import ./usr-tree.nix { };

  # Build the SBOM derivation (CycloneDX JSON).
  sbom = setFull.set.sbom {
    roots = composed.packages;
    name = "${composed.name}-${composed.version}";
  };

  # The usr tree with the image artifacts.
  usrTreeDrv = usrTreeLib.usrTree {
    composerOutput = composed // {
      files = composed.files // {
        "/usr/lib/golconda/config.json" = {
          text = builtins.toJSON normalizedConfig;
          mode = "0644";
        };
        "/usr/lib/golconda/schema.json" = {
          text = builtins.toJSON schema;
          mode = "0644";
        };
      };
    };
    inherit (setFull) platform;
    inherit (composed) version;
    sbomDrv = sbom;
  };

in
{
  inherit composed;
  usrTree = usrTreeDrv;
  config = normalizedConfig;
  inherit (setFull) platform pkgs;
  inherit (composed) version name;
}
