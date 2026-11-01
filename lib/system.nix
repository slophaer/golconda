# lib/system.nix: the entry point for one Golconda system.
#
# mkSystem { config; platform?; sources?; extra?; } → {
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
  platform ? system,
  system ? builtins.currentSystem,
  sources ? import ../nix/sources.nix,
  extra ? { },
}:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    elem
    filter
    isAttrs
    isPath
    isString
    length
    mapAttrs
    match
    split
    stringLength
    substring
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

  givenOptions = mergeDeep loadedOptions extra // {
    # /pkgs.target is always from the set, never from extra
    "/pkgs".target = setFull.set;
  };

  # A table names a module, and an option name must be one the module
  # declares: adios applies only declared options and ignores the rest, so a
  # misspelt name would silently keep the default. One
  # check covers every route into the tree: the TOML loader's tables (its
  # path check is config.nix), an attrset config, and `extra`.
  moduleAt =
    p:
    builtins.foldl' (mods: part: mods.modules.${part}) (tree { }) (
      builtins.filter (s: builtins.isString s && s != "") (builtins.split "/" p)
    );

  checkOptionNames =
    p: given:
    if p != "/pkgs" && !(elem p configLib.validPaths) then
      throw "golconda: unknown module path '${p}' in config; valid paths: ${concatStringsSep ", " configLib.validPaths}"
    else
      let
        declared = attrNames ((moduleAt p).options or { });
        unknown = filter (k: !(elem k declared)) (attrNames given);
      in
      if unknown != [ ] then
        throw "golconda: ${p} has no option ${
          concatStringsSep ", " (map (k: "'${k}'") unknown)
        } (a misspelt option would silently keep the default); valid options: ${concatStringsSep ", " declared}"
      else
        true;

  # deepSeq over a list of booleans: every module's option names are checked
  # now, not when something later reads the table.
  mergedOptions = builtins.deepSeq (map (p: checkOptionNames p givenOptions.${p}) (
    attrNames givenOptions
  )) givenOptions;

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

  # The image id becomes os-release ID=, the artifact file name stem and the
  # sysupdate MatchPattern: one grammar that is safe in all
  # three, checked before anything renders it.
  checkImageName =
    name:
    if name == null then
      true
    else if match "[A-Za-z0-9][A-Za-z0-9._-]*" name != null then
      true
    else
      throw "golconda: /system.name '${name}' is not an image id: use letters, digits and _ . - and start with a letter or digit (the id is os-release ID=, the artifact file name stem and the sysupdate match pattern)";

  # The composed system: /system with all fragments.
  composedRaw =
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

  # updateSource is the Path= of every sysupdate transfer: one URL or absolute
  # path, never several lines.
  hasPrefix = p: s: substring 0 (stringLength p) s == p;
  checkUpdateSource =
    source:
    if !isString source then
      true # the option type reports a non-string
    else if length (split "[[:space:][:cntrl:]]" source) > 1 then
      throw "golconda: /system.updateSource '${source}' must not contain whitespace or a line break: it is the Path= of every sysupdate transfer, and a line break would add an INI directive"
    else if hasPrefix "/" source || match ".*://.*" source != null then
      true
    else
      throw "golconda: /system.updateSource '${source}' is neither a URL (https://…) nor an absolute path";

  # Forcing composed (any field, including name) runs the name and source checks.
  composed = builtins.seq (checkImageName (systemOptions.name or null)) (
    builtins.seq (checkUpdateSource (systemOptions.updateSource or null)) composedRaw
  );

  # The schema for this tree.
  schemaLib = import ./schema.nix { };
  moduleFiles = (import ./module-docs.nix { }).discoverModulePaths ../modules;
  schema = schemaLib.toJsonSchemaWith {
    files = moduleFiles;
    root = toString ../.;
  } (tree { });

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

      moduleAt =
        path:
        builtins.foldl' (mods: part: mods.modules.${part}) (tree { }) (
          builtins.filter (s: builtins.isString s && s != "") (builtins.split "/" path)
        );

      rows =
        path: given:
        let
          declared = (moduleAt path).options or { };
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
