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
      inherit (sys) fragments packages;
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
  (check "mkSystem: the build's own fragments are named and listed in modules.json" (
    let
      sys = import ../../lib/system.nix {
        inherit sources platform;
        system = platform;
        config = head;
        extraFragments = [ { name = "/image/test"; } ];
      };
    in
    sys.fragments == [
      "/image/hwdb"
      "/image/test"
    ]
    && agrees sys
    &&
      throws
        (import ../../lib/system.nix {
          inherit sources platform;
          system = platform;
          config = head;
          extraFragments = [ { } ];
        }).composed.units
  ))
  (check "config: /system has no fragments option: a component enters by its table" (
    !(tryEval (
      configLib.loadConfigText ''
        [["/system".fragments]]
        name = "x"
      ''
    )).success
    &&
      throws
        (mkSystem (
          head
          // {
            "/system" = head."/system" // {
              fragments = [ sshd ];
            };
          }
        )).composed.units
  ))
  (check "downstream: modules/ beside the document is mounted under /local and selected by its table"
    (
      let
        sys = mkSystem ../fixtures/downstream/server.toml;
      in
      agrees sys
      && sys.inventory."/local".role == "group"
      && sys.inventory."/local/motd".reason == "config"
      && sys.composed.files."/usr/lib/motd".text == "hello\n"
      && elem "/local/motd" (originsOf sys.composed)
      &&
        sys.config."/local/motd".text == {
          value = "hello\n";
          explicit = true;
        }
    )
  )
  (check "downstream: packages/ joins the target set; a replacement is recorded" (
    let
      sys = mkSystem ../fixtures/downstream/server.toml;
      json = fromJSON sys.artifacts."/usr/lib/golconda/modules.json".text;
    in
    sys.packages == {
      openssh.replaces = "golconda";
      openssh-alias.replaces = null;
      ripgrep.replaces = "repkgs";
      hello.replaces = null;
    }
    && json.packages == sys.packages
    # each name is the downstream package: the fixtures' versions mark them
    && sys.pkgs.hello.version == "0.0.1"
    # a replacement wins over repkgs' and Golconda's own package of that name
    && sys.pkgs.ripgrep.version == "0.0.2"
    && sys.pkgs.openssh.version == "0.0.3"
    # a module brings the new package into the image
    && builtins.elem sys.pkgs.hello sys.composed.packages
    &&
      sys.composed.packageOrigins.${(import ../../modules/lib/merge.nix).pkgKey sys.pkgs.hello} == [
        "/local/hello"
      ]
  ))
  (check "downstream: a package named after a repkgs alias is refused (the alias would win)" (
    throws (mkSystem ../fixtures/downstream-alias/server.toml).composed.units
  ))
  (check "downstream: no packages/ beside the document, no downstream packages" (
    (mkSystem ../fixtures/downstream-none/server.toml).packages == { }
  ))
  (check "downstream: a module's schema has its options and the file it is declared in" (
    let
      sys = mkSystem ../fixtures/downstream/server.toml;
      sch = fromJSON sys.artifacts."/usr/lib/golconda/schema.json".text;
    in
    sch.properties."/local/motd".properties.text."x-golconda-declaredIn".file
    == "modules/motd/default.nix"
  ))
  (check "downstream: [golconda] names the module directory; without a table the module is out" (
    let
      sys = mkSystem ../fixtures/downstream-explicit/server.toml;
    in
    agrees sys
    && sys.inventory."/local/motd".included == false
    && !(sys.composed.files ? "/usr/lib/motd")
  ))
  (check "downstream: no modules/ beside the document, no /local; a named directory must exist" (
    !((mkSystem ../fixtures/downstream-none/server.toml).inventory ? "/local")
    && throws (mkSystem ../fixtures/downstream-none/missing.toml).inventory
    && !(tryEval (configLib.readProject { golconda.nope = 1; })).success
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
    !(sch.properties."/system".properties ? components) && sch.properties."/system".properties ? name
  ))
]
