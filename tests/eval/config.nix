# Checks of the TOML config loader, the config-in-store boundary and lib/system.nix's mkSystem entry point.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  a,
  check,
  configLib,
  f,
  factoryDir,
  factoryOf,
  filesThrow,
  hasInfix,
  pamSshd,
  platform,
  sources,
  sshdConfig,
  system,
  unit,
  ...
}:
let
  inherit (builtins)
    attrNames
    deepSeq
    elem
    match
    tryEval
    ;
in
[
  # 6. TOML config loader
  (check "config: validPaths includes sshd and not /pkgs" (
    builtins.elem "/services/sshd" configLib.validPaths
    && builtins.elem "/system" configLib.validPaths
    && !builtins.elem "/pkgs" configLib.validPaths
  ))
  (check "config: a /pkgs table is refused: the set is not data" (
    !(tryEval (configLib.loadConfigText "[\"/pkgs\"]\nset = \"repkgs\"\n")).success
    && !(configLib.loadConfig ../../examples/server.toml).options ? "/pkgs"
  ))
  (check "config: loadConfig parses server.toml" (
    let
      cfg = configLib.loadConfig ../../examples/server.toml;
    in
    cfg.options."/system".name == "server" && cfg.options."/services/sshd".port == 22
  ))
  (check "config: loadConfig rejects unknown table" (
    !(tryEval (configLib.loadConfig ../../examples/bad.toml)).success
  ))
  # The loader checks option names too: its options are safe to hand to
  # f.modules (the probe: prot = 2222 kept Port 22 through loadAndApply)
  (check "config: loadConfigText refuses a misspelt option and names it" (
    let
      load = text: tryEval (deepSeq (configLib.loadConfigText text).options true);
    in
    !(load "[\"/services/sshd\"]\nprot = 2222\n").success
    && (load "[\"/services/sshd\"]\nport = 2222\n").success
    && configLib.optionError "/services/sshd" { prot = 2222; } != null
    && hasInfix "/services/sshd has no option 'prot'" (
      configLib.optionError "/services/sshd" { prot = 2222; }
    )
  ))
  (check "config: mkSystem is the one route that applies a document" (
    !(configLib ? loadAndApply) && !(configLib ? withPkgs) && !(f.configLib ? loadAndApply)
  ))
  # 10a. Positive: sshd_config in /usr/lib has no credential paths
  (check "boundary: sshd_config has no %d or credential paths" (
    !hasInfix "%d/" sshdConfig
    && !hasInfix "$CREDENTIALS_DIRECTORY" sshdConfig
    && !hasInfix "/etc/credstore" sshdConfig
    # credential refs are only in the unit's ExecStart
    && hasInfix "%d/sshd-hostkey.key" unit
  ))
  # 10b. Negative: app.files refuses /etc/credstore absolute path
  (check "boundary: app.files refuses /etc/credstore path" (
    a.files.verify { "conf" = "Secret=/etc/credstore/key\n"; } != null
    && hasInfix "/etc/credstore" (a.files.verify { "conf" = "Secret=/etc/credstore/key\n"; })
  ))
  # 10c. Negative: a file path under /etc outside the factory module throws
  (check "boundary: files under /etc outside factory throw" (
    # The composer only accepts files under /usr; /etc files must go through /factory
    filesThrow [ { files."/etc/motd" = "hello"; } ]
    && filesThrow [ { files."/etc/ssh/sshd_config" = "Port 22"; } ]
  ))
  # 10e. Positive: factory extraFile with plain text passes
  (check "boundary: factory extraFile with plain text passes" (
    let
      r = factoryOf { extraFiles."motd" = "Welcome to Golconda\n"; };
    in
    r.files."${factoryDir}/motd" == "Welcome to Golconda\n"
  ))
  # 10f. Negative: the composer refuses files outside /usr
  (check "boundary: composer refuses files outside /usr" (
    filesThrow [ { files."/var/lib/app/data" = "x"; } ]
    && filesThrow [ { files."/run/lock" = "x"; } ]
    && filesThrow [ { files."/tmp/test" = "x"; } ]
  ))
  # 13. lib/system.nix: mkSystem entry point
  (check "mkSystem: a configured service, /vars and /factory are in the system" (
    system.units ? "sshd.service"
    && system.files ? "/usr/lib/golconda/golconda-var-run"
    && (system.files."${factoryDir}/pam.d/sshd".text or null) == pamSshd
    && elem "L /etc/pam.d/sshd - - - - ${factoryDir}/pam.d/sshd" system.tmpfiles
    && elem "L /etc/localtime - - - - /usr/share/zoneinfo/UTC" system.tmpfiles
  ))
  (check "mkSystem: server.toml yields name and version" (
    let
      mkSystem =
        args:
        import ../../lib/system.nix (
          args
          // {
            inherit sources platform;
            system = platform;
          }
        );
      sys = mkSystem { config = ../../examples/server.toml; };
    in
    sys.name == "server" && sys.version == "20261031.1"
  ))
  (check "mkSystem: a package option takes a package name from the target set" (
    let
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
      sys = mkSystem (head // { "/services/sshd".package = "openssh"; });
      unit = sys.composed.units."sshd.service";
    in
    # the unit runs the named package's sshd, and config.json keeps the name as written
    builtins.elem sys.pkgs.openssh sys.composed.packages
    && hasInfix "ExecStart=/usr/bin/sshd " unit
    &&
      sys.config."/services/sshd".package == {
        value = "openssh";
        explicit = true;
      }
    && !(tryEval (
      deepSeq (mkSystem (head // { "/services/sshd".package = "no-such-package"; })).composed.units true
    )).success
  ))
  (check "mkSystem: config.json has the sshd table and no derivation strings" (
    let
      mkSystem =
        args:
        import ../../lib/system.nix (
          args
          // {
            inherit sources platform;
            system = platform;
          }
        );
      sys = mkSystem { config = ../../examples/server.toml; };
      cfg = sys.config;
      cfgJson = builtins.toJSON cfg;
    in
    cfg ? "/services/sshd"
    && cfg."/services/sshd".port.value == 22
    # no store paths in the JSON
    && match ".*(/nix/store).*" cfgJson == null
  ))
  (check "mkSystem: a TOML with an unknown module path throws with the path in the message" (
    let
      mkSystem =
        args:
        import ../../lib/system.nix (
          args
          // {
            inherit sources platform;
            system = platform;
          }
        );
      badConfig = ../fixtures/unknown-module.toml;
      options = builtins.fromTOML (builtins.readFile badConfig);
      result = tryEval (deepSeq (mkSystem { config = badConfig; }).name true);
    in
    builtins.isPath badConfig
    && !result.success
    && hasInfix "unknown module path '/unknown/module'" (
      configLib.optionError "/unknown/module" options."/unknown/module"
    )
  ))
  # entry point: system is explicit, platform follows it, no builtins.currentSystem
  (check "mkSystem: platform defaults to system, evaluated purely" (
    let
      sys = import ../../lib/system.nix {
        inherit sources;
        config = ../../examples/server.toml;
        system = "aarch64-linux";
      };
    in
    sys.platform.name == "aarch64-linux"
  ))
  (check "examples/pins/golconda is a pin lib.readPins reads: the mirror's tarball at a full rev" (
    let
      s = (import ../../lib/pins.nix).specs ../../examples/pins;
      prefix = "https://github.com/slophaer/golconda/archive/";
    in
    builtins.attrNames s == [ "golconda" ]
    && builtins.match "${prefix}[0-9a-f]{40}\\.tar\\.gz" s.golconda.url != null
  ))
  # An option name no module declares is an error, not a silent
  # default; every route into the tree is checked
  (check "config: a misspelt option is refused, and a declared one accepted" (
    let
      mkSystem =
        args:
        import ../../lib/system.nix (
          args
          // {
            inherit sources platform;
            system = platform;
          }
        );
      base = {
        "/system" = {
          name = "t";
          version = "20261031.1";
        };
      };
      accepted = config: (tryEval (deepSeq (mkSystem { inherit config; }).name true)).success;
    in
    # sshd declares port, not prot (the probe: Port 22 was emitted for prot)
    !(accepted (base // { "/services/sshd".prot = 2222; }))
    # a declared option still passes
    && accepted (
      base
      // {
        "/services/sshd" = {
          port = 2222;
          authorizedKeys = [ "ssh-ed25519 AAAA t" ];
        };
      }
    )
    # every table of an attrset config is checked too
    && !(accepted (base // { "/network".netwroks = { }; }))
  ))
  # The image id has one grammar, safe in os-release, the artifact
  # file name and the sysupdate match pattern
  (check "config: the image id grammar is checked before it renders" (
    let
      mkSystem =
        args:
        import ../../lib/system.nix (
          args
          // {
            inherit sources platform;
            system = platform;
          }
        );
      composedOf =
        name:
        (mkSystem {
          config = {
            "/system" = {
              inherit name;
              version = "20261031.1";
            };
          };
        }).composed;
      named = name: (tryEval (deepSeq (composedOf name).name true)).success;
      # any field of the composed system, not only the name, runs the check
      unitsOf = name: (tryEval (deepSeq (attrNames (composedOf name).units) true)).success;
    in
    !(named "a/../b c")
    && !(named "a\nb")
    && !(named "hôte")
    && named "my-host_2.1"
    && !(unitsOf "a b")
    && unitsOf "my-host_2.1"
  ))
  (check "config: a line break in updateSource cannot add an INI section" (
    let
      mkSystem =
        args:
        import ../../lib/system.nix (
          args
          // {
            inherit sources platform;
            system = platform;
          }
        );
      withSource =
        updateSource:
        (tryEval (
          deepSeq
            (mkSystem {
              config = {
                "/system" = {
                  name = "t";
                  version = "20261031.1";
                  inherit updateSource;
                };
              };
            }).name
            true
        )).success;
    in
    !(withSource "https://example.com/\n[Evil]") && withSource "https://example.com/releases/"
  ))
]
