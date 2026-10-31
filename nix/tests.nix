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
  adios = import sources.adios;
  types = adios.adios.types;
  a = import ../modules/lib/app.nix { inherit types; };
  s = import ../modules/lib/service.nix { inherit types; };
  v = import ../modules/lib/var.nix { inherit types; };
  schemaLib = import ../lib/schema.nix { };
  moduleDocs = import ../lib/module-docs.nix { };
  docs = moduleDocs.toMarkdown (schemaLib.toJsonSchema (f.modules { }));
  configLib = import ../lib/config.nix {
    tree = f.modules { };
    inherit (f) modules;
  };
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

  compose =
    fragments:
    (f.modules {
      options."/system" = {
        name = "t";
        version = "0";
        inherit fragments;
      };
    }).modules.system
      { };
  # the composer's files, forced: a type error in a file fires here
  filesOf =
    fragments:
    let
      r = (compose fragments).files;
    in
    deepSeq r r;
  filesThrow = fragments: !(tryEval (filesOf fragments)).success;

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
  sshdConfig = system.files."/usr/lib/sshd/sshd_config".text;

  # 1a. sshd with certificates: a user CA, principals, a KRL and a host certificate
  certTree = f.modules {
    options."/services/sshd" = {
      package = standIn;
      trustedUserCAKeys = [ "ssh-ed25519 AAAA user-ca" ];
      principals.root = [ "alice@example.com" ];
      revokedKeys = "sshd-revoked-keys";
      hostCertificate = true;
    };
  };
  certSshd = compose [ (certTree.modules.services.modules.sshd { }) ];
  certUnit = certSshd.units."sshd.service";
  certConfig = certSshd.files."/usr/lib/sshd/sshd_config".text;
  sshdOptions = attrNames (import ../modules/services/sshd/default.nix { inherit types; }).options;
  sshdTree =
    opts:
    f.modules {
      options."/services/sshd" = {
        package = standIn;
      }
      // opts;
    };
  sshdThrows = opts: throws (compose [ ((sshdTree opts).modules.services.modules.sshd { }) ]);

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
      hasInfix "ExecStart=/usr/lib/golconda/golconda-var-run sshd-hostkey \"key\" \"key.pub\"" varUnit
    ))
    (check "var: manifest and script" (
      system.files ? "/usr/lib/golconda/vars.d/sshd-hostkey.json"
      && system.files ? "/usr/lib/golconda/vars.d/sshd-hostkey.sh"
    ))
    (check "vars: runner installed once" (system.files ? "/usr/lib/golconda/golconda-var-run"))

    # 1a. keys and certificates only: the fixed lines, and no option can undo them
    (check "sshd: no password path" (
      all (l: hasInfix "\n${l}\n" sshdConfig) [
        "PasswordAuthentication no"
        "KbdInteractiveAuthentication no"
        "ChallengeResponseAuthentication no"
        "PermitRootLogin prohibit-password"
        "UsePAM yes"
        "LogLevel VERBOSE"
      ]
    ))
    (check "sshd: the option set has no auth switch" (
      sshdOptions == [
        "authorizedKeys"
        "hostCertificate"
        "package"
        "port"
        "principals"
        "revokedKeys"
        "trustedUserCAKeys"
      ]
    ))
    (check "sshd: without a CA no certificate lines" (
      !hasInfix "TrustedUserCAKeys" sshdConfig
      && !hasInfix "AuthorizedPrincipalsFile" sshdConfig
      && !hasInfix "HostCertificate" unit
      && !hasInfix "RevokedKeys" unit
    ))
    (check "sshd: user CA keys file" (
      certSshd.files."/usr/lib/sshd/trusted_user_ca_keys".text == "ssh-ed25519 AAAA user-ca\n"
      && hasInfix "\nTrustedUserCAKeys /usr/lib/sshd/trusted_user_ca_keys\n" certConfig
    ))
    (check "sshd: principals file and AuthorizedPrincipalsFile" (
      certSshd.files."/usr/lib/sshd/principals.root".text == "alice@example.com\n"
      && hasInfix "\nAuthorizedPrincipalsFile /usr/lib/sshd/principals.%u\n" certConfig
    ))
    (check "sshd: host certificate credential and option" (
      hasInfix "LoadCredentialEncrypted=hostcert:sshd-host-cert" certUnit
      && hasInfix " -o HostCertificate=%d/hostcert" certUnit
    ))
    (check "sshd: revoked keys credential and option" (
      hasInfix "LoadCredentialEncrypted=sshd-revoked-keys:sshd-revoked-keys" certUnit
      && hasInfix " -o RevokedKeys=%d/sshd-revoked-keys" certUnit
    ))
    (check "sshd: the fixed lines survive the certificate options" (
      hasInfix "\nPasswordAuthentication no\n" certConfig
      && hasInfix "\nKbdInteractiveAuthentication no\n" certConfig
    ))
    (check "sshd: revokedKeys is one credential name" (sshdThrows {
      revokedKeys = "../x";
    }))
    (check "sshd: hostCertificate is a bool" (sshdThrows {
      hostCertificate = "yes";
    }))
    (check "sshd: principals are lists of strings" (sshdThrows {
      principals.root = "alice";
    }))
    (check "vars: runner is executable" (
      system.files."/usr/lib/golconda/golconda-var-run".mode == "0755"
    ))

    # 1b. a file is text (mode 0644) or { text; mode; }; the composer emits one shape
    (check "files: a string is a file with mode 0644" (
      (filesOf [ { files."/usr/lib/a/conf" = "x"; } ])."/usr/lib/a/conf" == {
        text = "x";
        mode = "0644";
      }
    ))
    (check "files: a record keeps its mode" (
      (filesOf [
        {
          files."/usr/lib/a/run" = {
            text = "#!/bin/sh\n";
            mode = "0755";
          };
        }
      ])."/usr/lib/a/run".mode == "0755"
    ))
    (check "files: a record without mode is 0644" (
      (filesOf [
        {
          files."/usr/lib/a/conf" = {
            text = "x";
          };
        }
      ])."/usr/lib/a/conf".mode == "0644"
    ))
    (check "files: a bad mode is a type error" (
      filesThrow [
        {
          files."/usr/lib/a/run" = {
            text = "x";
            mode = "rwxr-xr-x";
          };
        }
      ]
      && filesThrow [
        {
          files."/usr/lib/a/run" = {
            text = "x";
            mode = "755";
          };
        }
      ]
      && filesThrow [
        {
          files."/usr/lib/a/run" = {
            text = "x";
            mode = 493;
          };
        }
      ]
    ))
    (check "files: a record needs text and nothing else" (
      filesThrow [
        {
          files."/usr/lib/a/run" = {
            mode = "0755";
          };
        }
      ]
      && filesThrow [
        {
          files."/usr/lib/a/run" = {
            text = "x";
            source = ./tests.nix;
          };
        }
      ]
    ))
    (check "files: a string and a record for one path are a duplicate" (filesThrow [
      { files."/usr/lib/a/conf" = "x"; }
      {
        files."/usr/lib/a/conf" = {
          text = "x";
          mode = "0755";
        };
      }
    ]))

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
    (check "app.argv refuses an argument with a newline" (
      throws (
        s.render {
          name = "x";
          app = {
            package = standIn;
            argv = [ "a\nb" ];
          };
          user = "dynamic";
          sandbox = "strict";
        }
      )
    ))
    (check "app.argv accepts spaces and quotes (escaped by the renderer)" (
      !throws (
        s.render {
          name = "x";
          app = {
            package = standIn;
            argv = [
              "a b"
              "c\"d"
            ];
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
    (check "extraArgv renders a prefixed credential ref" (
      hasInfix " -o RevokedKeys=%d/k\n"
        (s.render {
          name = "x";
          app.package = standIn;
          extraArgv = [
            "-o"
            (s.credentialArg "RevokedKeys=" "k")
          ];
          credentials.k = "x.k";
          user = "dynamic";
          sandbox = "strict";
        }).units."x.service"
    ))
    (check "a credential prefix is one plain word" (
      throws (
        s.render {
          name = "x";
          app.package = standIn;
          extraArgv = [ (s.credentialArg "Revoked Keys=" "k") ];
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

    # 2b. an app file holds no per-machine value: a credential path or a key is refused,
    # and the message names the file (a.files.verify is null or the message)
    (check "app.files accepts a plain config" (
      a.files.verify {
        "sshd_config" =
          "Port 22\nAuthorizedKeysFile .ssh/authorized_keys /usr/lib/sshd/authorized_keys.%u\n";
        "motd" = "welcome";
      } == null
    ))
    (check "app.files refuses each per-machine marker and names the file" (
      all (
        m:
        let
          err = a.files.verify {
            ok = "Port 22\n";
            "bad.conf" = "Key ${m}x\n";
          };
        in
        err != null && hasInfix "'bad.conf'" err && hasInfix m err
      ) a.perMachineMarkers
      &&
        a.perMachineMarkers == [
          "%d/"
          "$CREDENTIALS_DIRECTORY"
          "-----BEGIN"
          "PRIVATE KEY"
        ]
    ))
    (check "render refuses an app file with a credential path" (
      throws (
        s.render {
          name = "x";
          app = {
            package = standIn;
            files."x.conf" = "RevokedKeys %d/krl\n";
          };
          user = "dynamic";
          sandbox = "strict";
        }
      )
    ))
    (check "render refuses an app file with a private key" (
      throws (
        s.render {
          name = "x";
          app = {
            package = standIn;
            files."key" = "-----BEGIN OPENSSH PRIVATE KEY-----\n";
          };
          user = "dynamic";
          sandbox = "strict";
        }
      )
    ))
    (check "app.files must be text" (a.files.verify { x = 1; } != null))

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
    (check "composer refuses a duplicate file" (filesThrow [
      { files."/usr/lib/foo/config" = "a"; }
      { files."/usr/lib/foo/config" = "b"; }
    ]))
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

    # 5. JSON Schema export
    (check "schema: exports JSON Schema 2020-12" (
      let
        schema = schemaLib.toJsonSchema (f.modules { });
      in
      schema."$schema" == "https://json-schema.org/draft/2020-12/schema"
      && schema.type == "object"
      && schema ? properties
    ))
    (check "schema: sshd module appears with its options" (
      let
        schema = schemaLib.toJsonSchema (f.modules { });
      in
      schema.properties ? "/services/sshd"
      && schema.properties."/services/sshd".properties ? port
      && schema.properties."/services/sshd".properties ? authorizedKeys
      && schema.properties."/services/sshd".properties ? principals
    ))
    (check "schema: principals is object of arrays of strings" (
      let
        schema = schemaLib.toJsonSchema (f.modules { });
        principals = schema.properties."/services/sshd".properties.principals;
      in
      principals.type == "object"
      && principals.additionalProperties.type == "array"
      && principals.additionalProperties.items.type == "string"
    ))
    (check "schema: port has default 22" (
      let
        schema = schemaLib.toJsonSchema (f.modules { });
        port = schema.properties."/services/sshd".properties.port;
      in
      port.type == "integer" && port.default == 22
    ))
    (check "schema: fixed sshd_config lines are not options" (
      let
        schema = schemaLib.toJsonSchema (f.modules { });
      in
      !(schema.properties."/services/sshd".properties ? PasswordAuthentication)
      && !(schema.properties."/services/sshd".properties ? UsePAM)
    ))
    (check "schema: system module has name, version, fragments" (
      let
        schema = schemaLib.toJsonSchema (f.modules { });
      in
      schema.properties ? "/system"
      && schema.properties."/system".properties ? name
      && schema.properties."/system".properties ? version
      && schema.properties."/system".properties ? fragments
    ))
    (check "module-docs: sshd page has the principals row and its default" (
      hasInfix "| `principals` | object of array of string | `{}` |" docs.pages."/services/sshd"
    ))
    (check "module-docs: sshd page has the port row with default 22" (
      hasInfix "| `port` | integer | `22` |" docs.pages."/services/sshd"
    ))
    (check "module-docs: index lists every module path" (
      all (p: hasInfix "[`${p}`](${docs.fileName.${p}})" docs.index) (attrNames docs.pages)
      &&
        attrNames docs.pages == [
          "/services/sshd"
          "/system"
          "/wrap"
        ]
    ))
    (check "module-docs: files hold every page and the index" (
      attrNames docs.files == [
        "index.md"
        "services-sshd.md"
        "system.md"
        "wrap.md"
      ]
    ))
    (check "module-docs: the book's SUMMARY links every generated page" (
      let
        summary = builtins.readFile ../docs/SUMMARY.md;
      in
      all (n: hasInfix "reference/modules/generated/${n})" summary) (attrNames docs.files)
    ))
    (check "module-docs: fixed sshd_config lines never appear as rows" (
      !(hasInfix "PasswordAuthentication" docs.pages."/services/sshd")
    ))
    (check "module-docs: opaque types are named and noted" (
      let
        p = moduleDocs.toMarkdown {
          properties."/x".properties.o."x-golconda-opaque" = "mystery";
        };
      in
      hasInfix "opaque `mystery`" p.pages."/x" && hasInfix "Opaque types are not described" p.pages."/x"
    ))
    (check "module-docs: a pipe or angle bracket in text cannot break the table" (
      let
        p = moduleDocs.toMarkdown {
          properties."/x".properties.o = {
            type = "string";
            description = "a|b <c>";
          };
        };
      in
      hasInfix "a\\|b &lt;c>" p.pages."/x"
    ))
    (check "module-docs: no opaque note for a fully described module" (
      !(hasInfix "Opaque types" docs.pages."/services/sshd")
    ))
    (check "schema: parseTypeName handles nested generics" (
      let
        p = schemaLib.parseTypeName "attrsOf<listOf<string>>";
      in
      p.base == "attrsOf" && p.args == [ "listOf<string>" ]
    ))
    (check "schema: parseTypeName handles union" (
      let
        p = schemaLib.parseTypeName "union<string,int>";
      in
      p.base == "union"
      &&
        p.args == [
          "string"
          "int"
        ]
    ))
    (check "schema: derivation maps to package marker" (
      let
        s = schemaLib.typeToSchemaByName "derivation";
      in
      s.type == "string" && s."x-golconda" == "package"
    ))

    # 6. TOML config loader
    (check "config: validPaths includes sshd" (
      builtins.elem "/services/sshd" configLib.validPaths && builtins.elem "/system" configLib.validPaths
    ))
    (check "config: loadConfig parses server.toml" (
      let
        cfg = configLib.loadConfig ../examples/server.toml;
      in
      cfg.options."/system".name == "server" && cfg.options."/services/sshd".port == 22
    ))
    (check "config: loadConfig rejects unknown table" (
      !(tryEval (configLib.loadConfig ../examples/bad.toml)).success
    ))
    (check "config: loadAndApply applies options to tree" (
      let
        appliedTree = configLib.loadAndApply ../examples/server.toml;
        # Check that the sshd module can be called and returns a fragment
        sshdFrag = appliedTree.modules.services.modules.sshd { };
      in
      sshdFrag ? units && sshdFrag ? files
    ))

    # 5. wrapApp and renderWrapped
    # A stub wrap function that records what it was called with
    (check "wrapApp calls wrap with the right record" (
      let
        # Stub wrap: returns a derivation-like record with the arguments it received
        stubWrap =
          args:
          standIn
          // {
            _wrapArgs = args;
          };
        wrapped = a.wrapApp stubWrap {
          package = standIn;
          argv = [
            "-f"
            "{files}/config"
          ];
          env.HOME = {
            set = "/var/lib/test";
          };
          files.config = "x";
        };
      in
      wrapped._wrapArgs.package == standIn
      &&
        wrapped._wrapArgs.argv == [
          "-f"
          "{root}/share/wrap/jq/config"
        ]
      && wrapped._wrapArgs.env.HOME.set == "/var/lib/test"
      && wrapped._wrapArgs.files.config == "x"
    ))
    (check "renderWrapped: ExecStart has only extraArgv" (
      let
        stubWrap = args: standIn // { _wrapArgs = args; };
        frag = s.renderWrapped stubWrap {
          name = "test";
          app = {
            package = standIn;
            argv = [
              "-D"
              "-f"
              "{files}/config"
            ];
            files.config = "Port 22\n";
          };
          extraArgv = [
            "-h"
            (s.credential "hostkey")
          ];
          credentials.hostkey = "test-key";
          user = "root";
          sandbox = "trusted";
        };
        unit = frag.units."test.service";
      in
      # ExecStart has only the binary and extraArgv, not argv
      hasInfix "ExecStart=/usr/bin/jq -h %d/hostkey\n" unit
      # No -D or -f in ExecStart (they're in the launch record)
      && !hasInfix "-D" unit
      && !hasInfix "-f" unit
    ))
    (check "renderWrapped: no files in fragment" (
      let
        stubWrap = args: standIn // { _wrapArgs = args; };
        frag = s.renderWrapped stubWrap {
          name = "test";
          app = {
            package = standIn;
            files.config = "x";
          };
          user = "dynamic";
          sandbox = "strict";
        };
      in
      frag.files == { }
    ))
    (check "renderWrapped: packages has the wrapped derivation" (
      let
        stubWrap =
          args:
          standIn
          // {
            _wrapArgs = args;
            _isWrapped = true;
          };
        frag = s.renderWrapped stubWrap {
          name = "test";
          app.package = standIn;
          user = "dynamic";
          sandbox = "strict";
        };
      in
      (builtins.head frag.packages)._isWrapped or false == true
    ))
    (check "renderWrapped: no env lines in unit" (
      let
        stubWrap = _args: standIn;
        frag = s.renderWrapped stubWrap {
          name = "test";
          app = {
            package = standIn;
            env.HOME = {
              set = "/var/lib/test";
            };
          };
          user = "dynamic";
          sandbox = "strict";
        };
        unit = frag.units."test.service";
      in
      # Environment= lines are not in the unit (they're in the launch record)
      !hasInfix "Environment=" unit
    ))

    # 5. Farm specification: bin links, farm dirs, dlopen, collision checks
    (check "farm: package with two bins emits two links" (
      let
        result = compose [
          {
            packages = [
              (withBin "tool-1" [
                "foo"
                "bar"
              ])
            ];
          }
        ];
      in
      builtins.length (builtins.filter (l: hasInfix "/usr/bin/" l.path) result.links) == 2
      && builtins.any (l: l.path == "/usr/bin/foo") result.links
      && builtins.any (l: l.path == "/usr/bin/bar") result.links
    ))
    (check "farm: farmDirs from farm declaration" (
      let
        pkg = withBin "systemd-1" [ ];
        result = compose [
          {
            packages = [ pkg ];
            farm."systemd-1" = [
              "lib/udev/rules.d"
              "lib/systemd/system"
            ];
          }
        ];
      in
      builtins.length result.farmDirs == 2
      && builtins.any (d: d.path == "/usr/lib/udev/rules.d") result.farmDirs
      && builtins.any (d: d.path == "/usr/lib/systemd/system") result.farmDirs
    ))
    (check "farm: dlopen links" (
      let
        pkg = withBin "tpm2-tss-1" [ ];
        result = compose [
          {
            packages = [ pkg ];
            dlopen."tpm2-tss-1" = [
              "libtss2-esys.so.0"
              "libtss2-rc.so.0"
            ];
          }
        ];
      in
      builtins.any (l: l.path == "/usr/lib/libtss2-esys.so.0") result.links
      && builtins.any (l: l.path == "/usr/lib/libtss2-rc.so.0") result.links
    ))
    (check "farm: farm dir declared twice by two packages errors" (
      let
        pkgA = withBin "a-1" [ ];
        pkgB = withBin "b-1" [ ];
      in
      !(tryEval (
        deepSeq
          (compose [
            {
              packages = [ pkgA ];
              farm."a-1" = [ "lib/security" ];
            }
            {
              packages = [ pkgB ];
              farm."b-1" = [ "lib/security" ];
            }
          ]).farmDirs
          true
      )).success
    ))
    (check "farm: file and farm link at same path errors" (
      let
        pkg = withBin "tool-1" [ ];
      in
      !(tryEval (
        deepSeq
          (compose [
            {
              packages = [ pkg ];
              dlopen."tool-1" = [ "libfoo.so.1" ];
            }
            { files."/usr/lib/libfoo.so.1" = "conflict"; }
          ]).links
          true
      )).success
    ))
    (check "farm: farm declaration for unknown package errors" (
      !(tryEval (
        deepSeq
          (compose [
            { farm."nonexistent-1" = [ "lib" ]; }
          ]).farmDirs
          true
      )).success
    ))

    # 6. Unit enablement: wantedBy renders .wants links and [Install] text
    (check "wantedBy: service has .wants link" (
      let
        svc = s.render {
          name = "test-svc";
          app.package = standIn;
          user = "dynamic";
          sandbox = "strict";
        };
      in
      builtins.any (
        l:
        l.path == "/usr/lib/systemd/system/multi-user.target.wants/test-svc.service"
        && l.target == "../test-svc.service"
      ) svc.links
    ))
    (check "wantedBy: [Install] section has WantedBy line" (
      let
        svc = s.render {
          name = "test-svc";
          app.package = standIn;
          user = "dynamic";
          sandbox = "strict";
        };
      in
      hasInfix "[Install]\nWantedBy=multi-user.target" svc.units."test-svc.service"
    ))
    (check "wantedBy: custom targets" (
      let
        svc = s.render {
          name = "early-svc";
          app.package = standIn;
          user = "dynamic";
          sandbox = "strict";
          wantedBy = [
            "sysinit.target"
            "basic.target"
          ];
        };
      in
      builtins.any (
        l: l.path == "/usr/lib/systemd/system/sysinit.target.wants/early-svc.service"
      ) svc.links
      && builtins.any (
        l: l.path == "/usr/lib/systemd/system/basic.target.wants/early-svc.service"
      ) svc.links
      && hasInfix "WantedBy=sysinit.target" svc.units."early-svc.service"
      && hasInfix "WantedBy=basic.target" svc.units."early-svc.service"
    ))
    (check "wantedBy: var unit has .wants link" (
      let
        varFrag = v.render {
          name = "test-var";
          secrets = [ "key" ];
          script = "echo";
        };
      in
      builtins.any (
        l:
        l.path == "/usr/lib/systemd/system/multi-user.target.wants/golconda-var-test-var.service"
        && l.target == "../golconda-var-test-var.service"
      ) varFrag.links
    ))
    (check "wantedBy: var unit [Install] section" (
      let
        varFrag = v.render {
          name = "test-var";
          secrets = [ "key" ];
          script = "echo";
        };
      in
      hasInfix "[Install]\nWantedBy=multi-user.target" varFrag.units."golconda-var-test-var.service"
    ))
    (check "wantedBy: bad target name rejected" (
      throws (
        s.render {
          name = "x";
          app.package = standIn;
          user = "dynamic";
          sandbox = "strict";
          wantedBy = [ "multi-user" ]; # missing .target
        }
      )
    ))

    # 7. Composer output includes links from services and vars
    (check "composer: merges links from services" (
      builtins.any (
        l: l.path == "/usr/lib/systemd/system/multi-user.target.wants/sshd.service"
      ) system.links
    ))
    (check "composer: merges links from vars" (
      builtins.any (
        l: l.path == "/usr/lib/systemd/system/multi-user.target.wants/golconda-var-sshd-hostkey.service"
      ) system.links
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
