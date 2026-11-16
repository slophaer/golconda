# The TOML loader: a document in, checked options out. A table `["/services/sshd"]` becomes
# `options."/services/sshd"` (docs/reference/config.md). An unknown table throws with the valid
# module paths, and an option name must be one the module declares: adios ignores the rest, so a
# misspelt name would silently keep the default. `/pkgs` is never a table, nor is
# `/system.components` (lib/components.nix selects them).
# The loader does not apply the options: lib/system.nix (mkSystem) binds /pkgs, runs
# `checkOptions` again over an attrset config, resolves package names and composes.
# `[golconda]` (`modules`, `packages`, `replaces`) says where the downstream repository's parts
# are, relative to the document (docs/features/extending.md). `readProject path` reads it
# without the tree; a downstream package takes the name of a Golconda or repkgs package only when
# `replaces` lists it (`replacementError`). `tree` is the evaluated tree, for validation.
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
    packages = "packages";
  };

  # { modules; packages; replaces; }: each directory a path or null, `replaces` a list of
  # package names. `dir` is the document's directory; `given` its `golconda` table.
  resolveProject =
    dir: given:
    let
      keys = attrNames projectDefaults ++ [ "replaces" ];
      unknown = filter (k: !(elem k keys)) (attrNames given);
      replaces = given.replaces or [ ];
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
      throw "golconda: [golconda] has no key ${concatStringsSep ", " unknown}; valid keys: ${concatStringsSep ", " keys}"
    else if !(builtins.isList replaces && builtins.all isString replaces) then
      throw "golconda: golconda.replaces must be a list of package names"
    else
      builtins.mapAttrs (k: _: resolve k) projectDefaults // { inherit replaces; };

  # The message for downstream packages that take existing names, or null. `downstream` is
  # name -> { replaces; } (nix/packages.nix: "golconda", "repkgs" or null); `allowed` is
  # [golconda] replaces. Every taken name must be allowed, and every allowed name taken: a
  # stale entry would allow a later replacement nobody reviewed.
  replacementError =
    { downstream, allowed }:
    let
      owner = {
        golconda = "Golconda's";
        repkgs = "repkgs'";
      };
      unlisted = filter (n: downstream.${n}.replaces != null && !(elem n allowed)) (attrNames downstream);
      stale = filter (n: (downstream.${n}.replaces or null) == null) allowed;
    in
    if unlisted != [ ] then
      let
        n = head unlisted;
      in
      "golconda: downstream package ${n} replaces ${
        owner.${downstream.${n}.replaces}
      } package of that name; add \"${n}\" to [golconda] replaces to allow it"
    else if stale != [ ] then
      "golconda: [golconda] replaces lists ${head stale}, but no downstream package replaces a package of that name"
    else
      null;

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
      builtins.mapAttrs (_: _: null) projectDefaults // { replaces = [ ]; };

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
    replacementError
    validPaths
    ;
}
