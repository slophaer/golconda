# The one walker of the module tree. Two views of the same tree, both here so that
# nothing else walks it:
#
#   modulePaths root        the module files, found the way adios finds them:
#                           [ { path = "/services/sshd"; filePath = <default.nix>; } ]
#   modulePathsAt prefix dir  the same for a directory mounted at `prefix` (/local)
#   pathComponents p        "/services/sshd" -> [ "services" "sshd" ]
#   moduleAt tree p         the module at path p of a loaded or evaluated tree
#   modulesOf tree          every module of that tree, parent before child:
#                           [ { path; module; } ]
#
# `modulePaths` mirrors `adios.lib.importModules`. A directory with a default.nix, and a
# `<name>.nix` file, is a module of the directory that is entered. The root is entered
# always; a module's own directory is entered only when its file declares `modules =`
# (the way /services imports its children). A file beside a module that no module
# declares, such as modules/base/foo.nix, is not a module and is not listed. A directory
# without a default.nix (modules/lib, shared types) is skipped.
#
# Usage:
#   let t = import ./lib/tree.nix { }; in t.modulePaths ../modules
_:
let
  inherit (builtins)
    any
    attrNames
    concatMap
    filter
    foldl'
    head
    isString
    match
    pathExists
    readDir
    readFile
    split
    ;

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

  # Does this module file declare children (`modules = ...;` on a line of its own)?
  declaresModules =
    file:
    any (l: isString l && match "[[:space:]]*modules[[:space:]]*=.*" l != null) (
      split "\n" (readFile file)
    );

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
