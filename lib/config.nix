# Load a TOML configuration document into adios tree options.
#
# A TOML document of the form:
#   ["/system"]
#   name = "myhost"
#   version = "20261031.1"
#
#   ["/services/sshd"]
#   port = 22
#   authorizedKeys = ["ssh-ed25519 AAAA..."]
#
# becomes:
#   { options."/system" = { name = "myhost"; version = "20261031.1"; };
#     options."/services/sshd" = { port = 22; authorizedKeys = [...]; }; }
#
# The loader's contract: a document in, checked options out. Table names are
# adios absolute paths (starting with /); an unknown table throws with the
# list of valid module paths. An option name must be one the module declares:
# adios applies only declared options and ignores the rest, so a misspelt
# name would silently keep the default; it throws with the valid names.
# `/pkgs` is never a table: the repkgs set is not data. Nor is `/system.components`:
# mkSystem selects the components (lib/components.nix).
#
# The loader does not apply the options. lib/system.nix (mkSystem) is the one
# entry point that does: it binds /pkgs, runs `checkOptions` again over an attrset
# config, resolves package names, and composes.
#
# Usage:
#   let cfg = import ./lib/config.nix { tree = f.modules { }; };
#   in cfg.loadConfig ./config.toml
#
# The one table that is not a module, `[golconda]`, says where the downstream repository's
# parts are, relative to the document: `modules` (default "modules", mounted under /local).
# A default directory that does not exist means none; a path the table names must exist.
# `readProject path` reads it without the tree: mkSystem needs it to build the tree.
#
# `tree` is the evaluated tree (f.modules { }), for path and option validation. `readProject`
# does not use it.
{ tree }:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    elem
    filter
    head
    isString
    pathExists
    readFile
    removeAttrs
    ;

  # The project table: its keys and their default directories.
  projectDefaults = {
    modules = "modules";
  };

  # { modules; }: each a path or null. `dir` is the document's directory; `given` its
  # `golconda` table.
  resolveProject =
    dir: given:
    let
      unknown = filter (k: !(projectDefaults ? ${k})) (attrNames given);
      resolve =
        key:
        if given ? ${key} then
          let
            v = given.${key};
            d = if isString v then dir + "/${v}" else v;
          in
          if !(isString v) && !(builtins.isPath v) || (isString v && dir == null) then
            throw "golconda: golconda.${key} must be a path relative to the configuration (a Nix path in an attrset configuration)"
          else if pathExists d then
            d
          else
            throw "golconda: golconda.${key} names '${toString v}', which does not exist"
        else if dir != null && pathExists (dir + "/${projectDefaults.${key}}") then
          dir + "/${projectDefaults.${key}}"
        else
          null;
    in
    if unknown != [ ] then
      throw "golconda: [golconda] has no key ${concatStringsSep ", " unknown}; valid keys: ${concatStringsSep ", " (attrNames projectDefaults)}"
    else
      builtins.mapAttrs (k: _: resolve k) projectDefaults;

  # The project of a TOML file (a path) or of options already loaded (an attrset, where
  # `golconda.modules` is a path and nothing has a default).
  readProject =
    config:
    if builtins.isPath config then
      resolveProject (dirOf config) ((builtins.fromTOML (readFile config)).golconda or { })
    else if builtins.isAttrs config then
      resolveProject null (config.golconda or { })
    else
      # mkSystem refuses any other config with its own message
      builtins.mapAttrs (_: _: null) projectDefaults;

  treeLib = import ./tree.nix { };
  inherit (import ./components.nix { }) internalOptions roleOf;
  moduleAt = treeLib.moduleAt tree;

  # Every module path with options, and every component, except /pkgs: the tables a document may have.
  # A component is a table even with no options: its table selects it.
  validPaths = filter (p: p != "/pkgs") (
    map (m: m.path) (
      filter (m: (m.module.options or { }) != { } || roleOf m.path m.module == "component") (
        treeLib.modulesOf tree
      )
    )
  );

  # The message for a table `given` at module path `p`, or null: an unknown
  # path, or an option name the module does not declare.
  optionError =
    p: given:
    if builtins.any (o: given ? ${o}) (internalOptions.${p} or [ ]) then
      "golconda: ${p} sets ${
        concatStringsSep ", " (filter (o: given ? ${o}) internalOptions.${p})
      }, which is not configuration: mkSystem sets it (lib/components.nix); add a module's table to include the module"
    else if !(elem p validPaths) then
      "golconda: unknown module path '${p}' in config; valid paths: ${concatStringsSep ", " validPaths}"
    else
      let
        declared = attrNames ((moduleAt p).options or { });
        unknown = filter (k: !(elem k declared)) (attrNames given);
      in
      if unknown == [ ] then
        null
      else
        "golconda: ${p} has no option ${
          concatStringsSep ", " (map (k: "'${k}'") unknown)
        } (a misspelt option would silently keep the default); valid options: ${concatStringsSep ", " declared}";

  # options, after every table is checked; "/pkgs" is skipped (mkSystem binds
  # its target, a document never has it).
  checkOptions =
    options:
    let
      errors = filter (e: e != null) (
        map (p: optionError p options.${p}) (filter (p: p != "/pkgs") (attrNames options))
      );
    in
    if errors == [ ] then options else throw (head errors);

  # Load and validate a TOML document given as text.
  # Strict: the result is { options; } only once every table is checked.
  loadConfigText =
    text:
    let
      toml = builtins.fromTOML text;
      # [golconda] is the project table, not a module (readProject)
      options = checkOptions (removeAttrs toml [ "golconda" ]);
    in
    if toml ? "/pkgs" then
      throw "golconda: /pkgs is not configuration: the repkgs set comes from nix (nix/default.nix), not from the document"
    else
      builtins.seq options { inherit options; };

  # Load and validate a TOML configuration file.
  loadConfig = path: loadConfigText (readFile path);
in
{
  inherit
    checkOptions
    loadConfig
    loadConfigText
    optionError
    readProject
    validPaths
    ;
}
