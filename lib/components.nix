# lib/components.nix: which modules a system includes, and why. The one place that selects them.
#
# Every module of the tree has one role:
#   component  returns a fragment for the image. A built-in component is in every system;
#              its table only configures it. An optional component is in a system when the
#              configuration has its table; an empty table selects it with its defaults.
#   provider   gives data to the modules that declare it as an input; no fragment (/pkgs)
#   composer   /system: unions the fragments of the selected components
#   group      holds child modules and has no impl (/services)
#
# An input (`inputs.<x>.path`) says whose result a module reads. It never selects a
# component: reading /pkgs installs nothing.
#
#   roleOf path module               the module's role
#   builtins                         the built-in components, in composition order
#   internalOptions                  module path -> [ option ]: options mkSystem sets, never a
#                                    document; the schema leaves them out, the loader refuses them
#   select options                   [ path ]: the built-ins, then the optional components
#                                    with a table, in name order
#   inventory tree options           { path = { role; inputs; included?; reason?; }; } for every
#                                    module; `included` and `reason` (builtin | config | null)
#                                    only on components. `tree` is the loaded tree (f.modules { }).
#   compose { modules; options; extraFragments ? [ ]; }
#                                    the composer output of `options`: `modules` is the tree
#                                    function (f.modules), `extraFragments` the build's own named
#                                    fragments, which are not modules (lib/image/index.nix). Each selected component's
#                                    fragment carries its module path as `name`, its origin.
#                                    A component enters by its table only: /system has no
#                                    other list of fragments. A downstream repository adds
#                                    a module (under /local), never a bare fragment.
_:
let
  on = import ../modules/lib/on.nix;
  inherit (builtins)
    attrNames
    attrValues
    elem
    filter
    listToAttrs
    map
    sort
    ;
  treeLib = import ./tree.nix { };

  builtins' = [
    "/base"
    "/network"
    "/security"
    "/trust"
    "/factory"
    "/vars"
  ];
  providers = [ "/pkgs" ];
  composer = "/system";
  internalOptions.${composer} = [ "components" ];

  roleOf =
    path: module:
    if path == composer then
      "composer"
    else if elem path providers then
      "provider"
    else if !(module ? impl) then
      "group"
    else
      "component";

  # The optional components a configuration selects: its tables that name a component
  # which is not built in. The loader refuses a table for an unknown path or for /pkgs.
  select =
    options:
    builtins'
    # attrNames is in name order already
    ++ filter (
      p: builtins.substring 0 1 p == "/" && !(elem p builtins') && p != composer && !(elem p providers)
    ) (attrNames options);

  inventory =
    tree: options:
    let
      selected = select options;
    in
    listToAttrs (
      map (
        m:
        let
          role = roleOf m.path m.module;
          included = elem m.path selected;
        in
        {
          name = m.path;
          value = {
            inherit role;
            inputs = sort (a: b: a < b) (
              filter (p: p != null) (map (i: i.path or null) (attrValues (m.module.inputs or { })))
            );
          }
          // (on (role == "component") {
            inherit included;
            reason =
              if elem m.path builtins' then
                "builtin"
              else if included then
                "config"
              else
                null;
          });
        }
      ) (treeLib.modulesOf tree)
    );

  compose =
    {
      modules,
      options,
      extraFragments ? [ ],
    }:
    let
      evaluated = modules { inherit options; };
      fragmentOf = path: treeLib.moduleAt evaluated path { } // { name = path; };
      systemOptions = options.${composer} or { };
    in
    (modules {
      options = options // {
        ${composer} = systemOptions // {
          components = map fragmentOf (select options) ++ extraFragments;
        };
      };
    }).modules.system
      { };
in
{
  builtins = builtins';
  inherit
    compose
    internalOptions
    roleOf
    inventory
    select
    ;
}
