# Load a TOML configuration document into adios tree options.
#
# A TOML document of the form:
#   ["/system"]
#   name = "myhost"
#   version = "1.0.0"
#
#   ["/services/sshd"]
#   port = 22
#   authorizedKeys = ["ssh-ed25519 AAAA..."]
#
# becomes:
#   { options."/system" = { name = "myhost"; version = "1.0.0"; };
#     options."/services/sshd" = { port = 22; authorizedKeys = [...]; }; }
#
# Table names are adios absolute paths (starting with /). Unknown table names
# throw with the list of valid module paths. `/pkgs` is never a table: the
# repkgs set is not data; `withPkgs set` binds a loader that adds it to the
# options, so `loadAndApply` can evaluate a module that needs a package.
#
# Usage:
#   let cfg = import ./lib/config.nix { inherit tree modules; };
#   in cfg.loadConfig ./config.toml
#   (cfg.withPkgs set).loadAndApply ./config.toml
#
# `tree` is the evaluated tree (f.modules { }) for path validation.
# `modules` is the module loader function (f.modules) for applying configs.
{
  tree,
  modules ? null,
  pkgsSet ? null,
}:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    elem
    filter
    foldl'
    mapAttrs
    readFile
    ;

  # Collect all valid module paths from the tree.
  collectPaths =
    prefix: mods:
    foldl' (
      acc: name:
      let
        mod = mods.${name};
        path = prefix + "/" + name;
        # Include this path if it has options
        thisPaths = if mod ? options && mod.options != { } then [ path ] else [ ];
        # Recurse into submodules
        subPaths = if mod ? modules && mod.modules != { } then collectPaths path mod.modules else [ ];
      in
      acc ++ thisPaths ++ subPaths
    ) [ ] (attrNames mods);

  validPaths = filter (p: p != "/pkgs") (collectPaths "" tree.modules);

  # Check if a table name is a valid module path.
  isValidPath = p: elem p validPaths;

  # Load and validate a TOML document given as text.
  loadConfigText =
    text:
    let
      toml = builtins.fromTOML text;
      tables = attrNames toml;

      # Find invalid table names
      invalidTables = filter (t: !isValidPath t) tables;

      # Build the options attrset
      options = mapAttrs (
        tableName: tableValue:
        if isValidPath tableName then
          tableValue
        else
          throw "golconda: unknown module path '${tableName}' in config; valid paths: ${concatStringsSep ", " validPaths}"
      ) toml;
    in
    if toml ? "/pkgs" then
      throw "golconda: /pkgs is not configuration: the repkgs set comes from nix (nix/default.nix), not from the document"
    else if invalidTables != [ ] then
      throw "golconda: unknown module path(s) in config: ${concatStringsSep ", " invalidTables}; valid paths: ${concatStringsSep ", " validPaths}"
    else
      {
        options = options // (if pkgsSet == null then { } else { "/pkgs".set = pkgsSet; });
      };

  # Load and validate a TOML configuration file.
  loadConfig = path: loadConfigText (readFile path);

  # Load config and apply it to the tree, returning an evaluated tree.
  # Requires the `modules` function to be passed to this library.
  loadAndApply =
    path:
    let
      cfg = loadConfig path;
    in
    if builtins.isFunction modules then
      modules cfg
    else
      throw "loadAndApply requires the modules function; pass it to config.nix";

  # Validate a TOML config against the schema without applying it.
  # Returns null if valid, or an error message.
  validateConfig =
    path:
    let
      result = builtins.tryEval (loadConfig path);
    in
    if result.success then null else result.value;

  # The same loader with the repkgs set bound: its options carry "/pkgs".set.
  withPkgs =
    set:
    import ./config.nix {
      inherit tree modules;
      pkgsSet = set;
    };
in
{
  inherit
    loadConfig
    loadConfigText
    loadAndApply
    validateConfig
    validPaths
    withPkgs
    ;
}
