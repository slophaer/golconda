# The one walker of the module tree; nothing else walks it.
#   modulePaths root          [ { path = "/services/sshd"; filePath = <default.nix>; } ]
#   modulePathsAt prefix dir  the same for a directory mounted at `prefix` (/local)
#   pathComponents p          "/services/sshd" -> [ "services" "sshd" ]
#   moduleAt tree p           the module at path p of a loaded or evaluated tree
#   modulesOf tree            every module, parent before child: [ { path; module; } ]
# `modulePaths` finds the files the way `adios.lib.importModules` does. adios keeps no file of a
# loaded module, so the walker pairs what adios loads with the directory. A module's directory is
# entered only when the module has `modules`; a directory without a default.nix (modules/lib) is
# skipped.
_:
let
  inherit (builtins)
    attrNames
    concatMap
    filter
    foldl'
    head
    isString
    match
    pathExists
    readDir
    split
    ;

  # the argument adios.lib.importModules calls a module file with
  inherit (import (import ../pins).adios) adios;

  # The components of a module path: "/services/sshd" -> [ "services" "sshd" ].
  pathComponents = p: filter (c: isString c && c != "") (split "/" p);

  # The module at path `p` ("/services/sshd") of `tree`. A tree is loaded
  # (`f.modules { }`) or evaluated; both nest a submodule under `modules.<name>`.
  moduleAt = tree: p: foldl' (mod: part: mod.modules.${part}) tree (pathComponents p);

  # Every module under `tree`, parent before child, in name order: [ { path; module; } ].
  modulesOf =
    tree:
    let
      go =
        prefix: mods:
        concatMap (
          name:
          let
            module = mods.${name};
            path = "${prefix}/${name}";
          in
          [ { inherit path module; } ] ++ go path (module.modules or { })
        ) (attrNames mods);
    in
    go "" (tree.modules or { });

  # Does this module file declare children? Loaded as importModules loads it: a module
  # with `modules` has them, in its own directory.
  declaresModules = file: (import file adios) ? modules;

  # The module files of directory `dir`, whose modules sit under `prefix`.
  walk =
    prefix: dir:
    let
      entries = readDir dir;
    in
    concatMap (
      name:
      if entries.${name} == "directory" then
        let
          file = dir + "/${name}/default.nix";
          path = "${prefix}/${name}";
        in
        if pathExists file then
          [
            {
              inherit path;
              filePath = file;
            }
          ]
          ++ (if declaresModules file then walk path (dir + "/${name}") else [ ])
        else
          [ ]
      else
        let
          m = match "(.+)\\.nix$" name;
        in
        if m == null || name == "default.nix" then
          [ ]
        else
          [
            {
              path = "${prefix}/${head m}";
              filePath = dir + "/${name}";
            }
          ]
    ) (attrNames entries);

  # The module files under `root`, the directory passed to `adios.lib.importModules`.
  modulePaths = root: walk "" root;
  modulePathsAt = walk;
in
{
  inherit
    modulePaths
    modulePathsAt
    pathComponents
    moduleAt
    modulesOf
    ;
}
