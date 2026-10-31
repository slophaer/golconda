# Pure-Nix tests of the module model: types, renderers and the composer.
# scripts/lint evaluates this file with iets; it is `true` or throws with the
# failing test's name. No derivation is built.
#   iets eval --expr 'import ./nix/tests.nix { }'
{
  sources ? import ./sources.nix,
  platform ? "x86_64-linux",
}:
let
  inherit (builtins)
    all
    any
    attrNames
    deepSeq
    genList
    stringLength
    substring
    tryEval
    ;

  f = import ../default.nix;
  types = (import sources.adios).adios.types;
  s = import ../modules/lib/service.nix { inherit types; };
  v = import ../modules/lib/var.nix { inherit types; };
  inherit (import ./packages.nix { inherit sources platform; }) pkgs;

  # OpenSSH is not in repkgs yet; any derivation stands in for the type check
  # (the unit then says /usr/bin/jq, which the tests do not look at).
  standIn = pkgs.jq;

  # stand-ins for repkgs packages: `bin` exists only on those
  withBin = name: bin: pkgs.jq // { inherit name bin; };
  farmOf =
    packages:
    (
      (f.modules {
        options."/system" = {
          name = "farm";
          version = "0";
          fragments = [ { inherit packages; } ];
        };
      }).modules.system
        { }
    ).packages;

  check = name: cond: if cond then true else throw "golconda tests: ${name} failed";
  # forcing the units is enough: a type error fires before any field; the
  # package derivations stay unevaluated (repkgs needs ca-derivations to instantiate)
  throws = r: !(tryEval (deepSeq r.units r.units)).success;
  hasInfix =
    needle: hay:
    let
      n = stringLength needle;
      h = stringLength hay;
    in
    n <= h && any (i: substring i n hay == needle) (genList (i: i) (h - n + 1));

  # 1. sshd composes: the unit loads the host key credential and passes it
  tree = f.modules {
    options."/services/sshd" = {
      package = standIn;
      authorizedKeys = [ "ssh-ed25519 AAAA test" ];
    };
  };
  sshd = tree.modules.services.modules.sshd { };
  vars = tree.modules.vars { };
  system =
    (f.modules {
      options."/system" = {
        name = "test";
        version = "0";
        fragments = [
          sshd
          vars
        ];
      };
    }).modules.system
      { };
  unit = system.units."sshd.service";
  varUnit = system.units."golconda-var-sshd-hostkey.service";

  tests = [
    (check "sshd: LoadCredentialEncrypted" (
      hasInfix "LoadCredentialEncrypted=hostkey:sshd-hostkey.key" unit
    ))
    (check "sshd: credential ref renders as %d" (hasInfix " -h %d/hostkey" unit))
    (check "sshd: exec reads the app file" (hasInfix "-f /usr/lib/sshd/sshd_config" unit))
    (check "sshd: app file is installed" (system.files ? "/usr/lib/sshd/sshd_config"))
    (check "sshd: authorized keys file" (system.files ? "/usr/lib/sshd/authorized_keys.root"))
    (check "sshd: waits for the var" (hasInfix "After=golconda-var-sshd-hostkey.service" unit))
    (check "sshd: privsep user" (any (hasInfix "u sshd ") system.sysusers))
    (check "var: runs once" (
      hasInfix "ConditionPathExists=!/var/lib/golconda/vars/sshd-hostkey/done" varUnit
    ))
    (check "var: runner arguments" (
      hasInfix "golconda-var-run sshd-hostkey \"key\" \"key.pub\"" varUnit
    ))
    (check "var: manifest and script" (
      system.files ? "/usr/lib/golconda/vars.d/sshd-hostkey.json"
      && system.files ? "/usr/lib/golconda/vars.d/sshd-hostkey.sh"
    ))
    (check "vars: runner installed once" (system.files ? "/usr/lib/golconda/golconda-var-run"))

    # 2. a credential ref inside app.argv is a type error; in extraArgv it is not
    (check "app.argv refuses a credential ref" (
      throws (
        s.render {
          name = "x";
          app = {
            package = standIn;
            argv = [ (s.credential "k") ];
          };
          user = "dynamic";
          sandbox = "strict";
        }
      )
    ))
    (check "extraArgv accepts a declared credential ref" (
      !throws (
        s.render {
          name = "x";
          app.package = standIn;
          extraArgv = [ (s.credential "k") ];
          credentials.k = "x.k";
          user = "dynamic";
          sandbox = "strict";
        }
      )
    ))
    (check "extraArgv refuses an undeclared credential ref" (
      throws (
        s.render {
          name = "x";
          app.package = standIn;
          extraArgv = [ (s.credential "k") ];
          user = "dynamic";
          sandbox = "strict";
        }
      )
    ))

    # 3. a duplicate unit or file across two fragments is a composer error
    (check "composer refuses a duplicate unit" (
      throws (
        (f.modules {
          options."/system" = {
            name = "dup";
            version = "0";
            fragments = [
              { units."a.service" = "1"; }
              { units."a.service" = "2"; }
            ];
          };
        }).modules.system
          { }
      )
    ))
    (check "composer refuses a duplicate file" (
      !(tryEval (
        deepSeq
          (
            (f.modules {
              options."/system" = {
                name = "dup";
                version = "0";
                fragments = [
                  { files."/usr/lib/foo/config" = "a"; }
                  { files."/usr/lib/foo/config" = "b"; }
                ];
              };
            }).modules.system
              { }
          ).files
          true
      )).success
    ))
    (check "composer concatenates lists" (
      (
        (f.modules {
          options."/system" = {
            name = "cat";
            version = "0";
            fragments = [
              { sysusers = [ "a" ]; }
              { sysusers = [ "b" ]; }
            ];
          };
        }).modules.system
          { }
      ).sysusers == [
        "a"
        "b"
      ]
    ))

    # 3b. two packages with one /usr/bin name are a composer error
    (check "farm refuses one name in two packages" (
      !(tryEval (
        deepSeq (farmOf [
          (withBin "a-1" [ "x" ])
          (withBin "b-1" [
            "y"
            "x"
          ])
        ]) true
      )).success
    ))
    (check "farm accepts distinct names and the same package twice" (
      let
        a = withBin "a-1" [ "x" ];
      in
      builtins.length (farmOf [
        a
        (withBin "b-1" [ "y" ])
        a
      ]) == 3
    ))

    # 4. systemd escaping and the other type rules
    (check "render escapes % and $" (
      hasInfix "ExecStart=/usr/bin/jq 50%% $$HOME \"a b\""
        (s.render {
          name = "esc";
          app = {
            package = standIn;
            argv = [
              "50%"
              "$HOME"
              "a b"
            ];
          };
          user = "root";
          sandbox = "trusted";
        }).units."esc.service"
    ))
    (check "user must be dynamic, root or a sysusers line" (
      throws (
        s.render {
          name = "x";
          app.package = standIn;
          user = "bob";
          sandbox = "strict";
        }
      )
    ))
    (check "sandbox is an enum" (
      throws (
        s.render {
          name = "x";
          app.package = standIn;
          user = "root";
          sandbox = "lax";
        }
      )
    ))
    (check "env operation has one key" (
      throws (
        s.render {
          name = "x";
          app = {
            package = standIn;
            env.X = {
              set = "1";
              unset = true;
            };
          };
          user = "root";
          sandbox = "strict";
        }
      )
    ))
    (check "var file names are one component" (
      throws (
        v.render {
          name = "x";
          secrets = [ "../etc/shadow" ];
          script = "";
        }
      )
    ))
  ];
in
assert all (t: t) tests;
assert
  attrNames system.units == [
    "golconda-var-sshd-hostkey.service"
    "sshd.service"
  ];
true
