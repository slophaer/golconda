# lib/system.nix: the entry point for one Golconda system.
#
# mkSystem { config; platform?; sources?; extra?; } → {
#   composed;   # the composer output (units, files, links, packages, …)
#   usrTree;    # the /usr derivation
#   config;     # the normalized configuration (options by module path)
#   platform;   # the elaborated platform record
#   version;    # YYYYMMDD.N from /system
#   name;       # image id from /system
#   pkgs;       # the packages for this platform
# }
#
# `config` is a path to a TOML file or an attrset already loaded.
# `platform` defaults to the build host's (builtins.currentSystem).
# `sources` defaults to ../nix/sources.nix.
# `extra` is an attrset merged into the options the TOML gave: the only Nix hook.
#
# Usage:
#   let sys = import ./lib/system.nix { config = ./server.toml; };
#   in sys.usrTree
#
# Nix-only values (a package override, a fragment written in Nix) come through
# `extra`, so a configuration can be pure TOML or TOML + Nix.
{
  config,
  platform ? builtins.currentSystem,
  system ? builtins.currentSystem,
  sources ? import ../nix/sources.nix,
  extra ? { },
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

  # Load the repkgs set for this platform.
  setFull = import ../nix/packages.nix {
    inherit sources system platform;
  };

  # The configLib with the set bound, so modules can look up packages.
  configLib = import ./config.nix {
    tree = tree { };
    modules = tree;
    pkgsSet = setFull.set; # store-path-ok: setFull.set is the repkgs set
  };

  # Load configuration: a path is TOML, an attrset is already loaded options.
  loadedOptions =
    if isPath config then
      (configLib.loadConfig config).options
    else if isAttrs config then
      config
    else
      throw "golconda: config must be a path to a TOML file or an attrset of options";

  # Merge extra into the loaded options. Each module path is merged recursively:
  # extra."/system".name overrides just that field, not the whole /system entry.
  mergeDeep =
    a: b:
    builtins.mapAttrs (k: av: if b ? ${k} && isAttrs av && isAttrs b.${k} then av // b.${k} else av) a
    // builtins.removeAttrs b (attrNames a);

  mergedOptions = mergeDeep loadedOptions extra // {
    # /pkgs.target is always from the set, never from extra
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

  serviceFragments = map (
    path:
    let
      # Path like "/services/sshd" -> evaluated.modules.services.modules.sshd
      # builtins.split returns [ "" [ ] "services" [ ] "sshd" ], filter out non-strings and empty strings
      parts = builtins.filter (s: builtins.isString s && s != "") (builtins.split "/" path);
      # parts = [ "services" "sshd" ]
      modPath = builtins.tail parts; # [ "sshd" ]
      getModule =
        parts: mods:
        if parts == [ ] then mods else getModule (builtins.tail parts) mods.modules.${builtins.head parts};
    in
    (getModule modPath evaluated.modules.services) { }
  ) configuredServices;

  varsFragment = evaluated.modules.vars { };
  factoryFragment = evaluated.modules.factory { };

  # The system options from the config (name, version, fragments, updateSource).
  systemOptions = mergedOptions."/system" or { };

  # The composed system: /system with all fragments.
  composed =
    (tree {
      options = mergedOptions // {
        "/system" = systemOptions // {
          fragments =
            (systemOptions.fragments or [ ])
            ++ serviceFragments
            ++ [
              varsFragment
              factoryFragment
            ];
        };
      };
    }).modules.system
      { };

  # The schema for this tree.
  schemaLib = import ./schema.nix { };
  schema = schemaLib.toJsonSchema (tree { });

  # The normalized configuration: what the TOML said after type-checking, no derivations.
  # One JSON object keyed by module path, for config.json.
  normalizedConfig =
    let
      # Walk the evaluated tree and extract option values, stripping derivations.
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

      # Extract the option values from each module path in the config.
      extractModuleValues =
        path: opts:
        if path == "/pkgs" then
          # Skip /pkgs: its set is not configuration data
          null
        else
          stripDerivations opts;
    in
    builtins.listToAttrs (
      builtins.filter (x: x.value != null) (
        map (path: {
          name = path;
          value = extractModuleValues path (mergedOptions.${path} or { });
        }) (attrNames mergedOptions)
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
