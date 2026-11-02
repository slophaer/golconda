# Checks of component selection (lib/components.nix): which modules enter a system, and why.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  composeWith,
  configLib,
  f,
  mkSystemFixture,
  platform,
  schemaLib,
  sources,
  sshd,
  ...
}:
let
  inherit (builtins)
    all
    attrNames
    attrValues
    concatLists
    elem
    filter
    fromJSON
    sort
    tryEval
    ;
  components = import ../../lib/components.nix { };
  tree = f.modules { };
  inventory = components.inventory tree;
  # every origin that emitted a file, a unit, a link or a package
  originsOf = r: concatLists (concatLists (map attrValues (attrValues r.origins)));
  throws = x: !(tryEval (builtins.deepSeq x x)).success;
  mkSystem =
    config:
    import ../../lib/system.nix {
      inherit sources platform config;
      system = platform;
    };
  head = {
    "/system" = {
      name = "t";
      version = "20261031.1";
    };
  };
  # the included components, and the module paths that emitted anything, sorted
  includedOf = inv: filter (p: inv.${p}.included or false) (attrNames inv);
  emittersOf =
    r: inv:
    sort (a: b: a < b) (
      filter (p: inv ? ${p}) (
        builtins.attrNames (
          builtins.listToAttrs (
            map (o: {
              name = o;
              value = null;
            }) (originsOf r)
          )
        )
      )
    );
  # modules.json is the inventory and the fragments, and every included component, and no
  # other module, emitted something
  agrees =
    sys:
    fromJSON sys.artifacts."/usr/lib/golconda/modules.json".text == {
      modules = sys.inventory;
      inherit (sys) fragments;
    }
    && emittersOf sys.composed sys.inventory == includedOf sys.inventory;
in
[
  (check "components: every module has one role" (
    let
      inv = inventory { };
    in
    all (
      p:
      elem inv.${p}.role [
        "component"
        "provider"
        "composer"
        "group"
      ]
    ) (attrNames inv)
    && inv."/pkgs".role == "provider"
    && inv."/system".role == "composer"
    && inv."/services".role == "group"
    && inv."/base".role == "component"
    && inv."/services/sshd".role == "component"
  ))
  (check "components: every built-in is a component module of the tree" (
    let
      inv = inventory { };
    in
    all (p: inv ? ${p} && inv.${p}.role == "component") components.builtins
  ))
  (check "components: the built-ins are in every system, in order" (
    components.select { } == components.builtins
    &&
      components.builtins == [
        "/base"
        "/network"
        "/security"
        "/factory"
        "/vars"
      ]
  ))
  (check "components: an empty table selects an optional component" (
    elem "/services/sshd" (components.select { "/services/sshd" = { }; })
  ))
  (check "components: without its table an optional component is left out" (
    !(elem "/services/sshd" (components.select { "/system".name = "t"; }))
  ))
  (check "components: a built-in's table configures it and selects nothing more" (
    components.select { "/network".dns = [ "9.9.9.9" ]; } == components.builtins
  ))
  (check "components: the inventory says why a component is in the system" (
    let
      inv = inventory { "/services/sshd" = { }; };
      none = inventory { };
    in
    inv."/base".included
    && inv."/base".reason == "builtin"
    && inv."/services/sshd".included
    && inv."/services/sshd".reason == "config"
    && !none."/services/sshd".included
    && none."/services/sshd".reason == null
    # a provider or the composer is not a component: no `included`
    && !(inv."/pkgs" ? included)
    && !(inv."/system" ? included)
  ))
  (check "components: the inventory lists each module's inputs" (
    let
      inv = inventory { };
    in
    inv."/services/sshd".inputs == [ "/pkgs" ]
    && inv."/base".inputs == [ "/pkgs" ]
    && inv."/security".inputs == [ ]
    && inv."/system".inputs == [ ]
  ))
  (check "composer: an empty table composes the optional component" (
    let
      r = composeWith { "/services/sshd" = { }; };
    in
    r.units ? "sshd.service" && elem "/services/sshd" (originsOf r)
  ))
  (check "composer: without a table there is no optional component" (
    !((composeWith { }).units ? "sshd.service")
  ))
  (check "composer: every built-in's fragment has its path as origin" (
    let
      o = originsOf (composeWith { });
    in
    all (p: elem p o) components.builtins
  ))
  (check "composer: a component fragment without a name is refused" (
    throws (
      (f.modules {
        options."/system" = {
          name = "t";
          version = "20261031.1";
          components = [ { files = { }; } ];
        };
      }).modules.system
        { }
    )
  ))
  (check "config: /system.components is not configuration" (
    let
      r = tryEval (
        configLib.loadConfigText ''
          ["/system"]
          components = []
        ''
      );
    in
    !r.success
  ))
  (check "mkSystem: modules.json is the inventory, and it agrees with the image" (
    agrees mkSystemFixture
    && mkSystemFixture.inventory."/services/sshd".reason == "config"
    && mkSystemFixture.inventory."/factory".reason == "builtin"
  ))
  (check "mkSystem: an empty table includes the component, and the inventory says so" (
    let
      sys = mkSystem (head // { "/services/sshd" = { }; });
    in
    agrees sys && sys.inventory."/services/sshd".included && sys.composed.units ? "sshd.service"
  ))
  (check "mkSystem: no table, no component, and the inventory says so" (
    let
      sys = mkSystem head;
    in
    agrees sys && !sys.inventory."/services/sshd".included && !(sys.composed.units ? "sshd.service")
  ))
  (check "mkSystem: a fragment that is not a module is listed in modules.json" (
    let
      sys = mkSystem (
        head
        // {
          "/system" = head."/system" // {
            fragments = [
              { name = "local"; }
              { }
            ];
          };
        }
      );
    in
    sys.fragments == [
      "local"
      "fragments[1]"
      "/image/hwdb"
    ]
    && agrees sys
  ))
  (check "mkSystem: a component as a listed fragment is refused (it enters by its table)" (
    throws
      (mkSystem (
        head
        // {
          "/system" = head."/system" // {
            fragments = [ sshd ];
          };
        }
      )).composed.units
    &&
      throws
        (composeWith {
          "/system" = head."/system" // {
            fragments = [ sshd ];
          };
        }).units
  ))
  (check
    "mkSystem: config.json has a row for every included component and /system, no internal option"
    (
      let
        c = mkSystemFixture.config;
      in
      sort (a: b: a < b) (attrNames c)
      == sort (a: b: a < b) (includedOf mkSystemFixture.inventory ++ [ "/system" ])
      && !(c."/system" ? components)
    )
  )
  (check "schema: an internal option is not in the schema" (
    let
      sch = schemaLib.toJsonSchema (f.modules { });
    in
    !(sch.properties."/system".properties ? components)
    && sch.properties."/system".properties ? fragments
  ))
]
