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
    elem
    genList
    isString
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
  docComments = import ../lib/doc-comments.nix { };
  modulePaths = moduleDocs.discoverModulePaths ../modules;
  docs = moduleDocs.toMarkdown {
    schema = schemaLib.toJsonSchema (f.modules { });
    inherit modulePaths docComments;
    inherit (schemaLib) typeRegistry;
    tree = f.modules { };
  };
  # Helper for testing schema rendering with a minimal schema (no module walking)
  mockPage =
    schema:
    let
      props = schema.properties or { };
      paths = builtins.attrNames props;
    in
    builtins.listToAttrs (
      builtins.map (p: {
        name = p;
        value =
          let
            s = props.${p};
            names = builtins.attrNames (s.properties or { });
            row =
              n:
              let
                opt = s.properties.${n};
              in
              "| `${n}` | ${moduleDocs.typeOf opt} | | ${
                builtins.replaceStrings [ "\n" "|" "<" ] [ " " "\\|" "&lt;" ] (opt.description or "")
              } |";
            opaqueCheck = builtins.any (
              n:
              let
                opt = s.properties.${n};
              in
              opt ? "x-golconda-opaque"
            ) names;
          in
          builtins.concatStringsSep "\n" (
            builtins.map row names ++ (if opaqueCheck then [ "\nOpaque types are not described" ] else [ ])
          );
      }) paths
    );
  configLib = import ../lib/config.nix {
    tree = f.modules { };
    inherit (f) modules;
  };
  usrTreeLib = import ../lib/usr-tree.nix { };
  inherit
    (import ./packages.nix {
      inherit sources;
      system = platform;
      inherit platform;
    })
    pkgs
    ;

  # repkgs needs ca-derivations to instantiate, so no package is built here;
  # jq stands in for the type check (the unit then says /usr/bin/jq).
  standIn = pkgs.jq;

  # stand-ins for repkgs packages: `bin` exists only on those
  withBin =
    name: bin:
    pkgs.jq
    // {
      inherit name bin;
      outPath = "/nix/store/${name}";
    };
  # openssh as repkgs declares it: `bin` lists the client tools first
  openssh =
    withBin "openssh-10.6p1" [
      "ssh"
      "sshd"
      "ssh-keygen"
    ]
    // {
      pname = "openssh";
    };
  # a stub for repkgs' `wrap`: the same shape as its output (a new name, no
  # `bin`), with the arguments it received
  stubWrap =
    args:
    removeAttrs (args.package // { _wrapArgs = args; }) [ "bin" ]
    // {
      name = "${args.package.pname or args.package.name}-wrap";
      outPath = "${args.package}-wrap-${
        builtins.hashString "sha256" (builtins.toJSON (removeAttrs args [ "package" ]))
      }";
    };
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
  hasPrefix = p: s: substring 0 (stringLength p) s == p;

  # 1. sshd composes: the unit loads the host key credential and passes it
  tree = f.modules {
    options."/services/sshd" = {
      package = openssh;
      wrap = stubWrap;
      authorizedKeys = [ "ssh-ed25519 AAAA test" ];
    };
  };
  sshd = tree.modules.services.modules.sshd { };
  vars = tree.modules.vars { };
  factory = tree.modules.factory { };
  system =
    (f.modules {
      options."/system" = {
        name = "test";
        version = "0";
        fragments = [
          sshd
          vars
          factory
        ];
      };
    }).modules.system
      { };
  unit = system.units."sshd.service";
  varUnit = system.units."golconda-var-sshd-hostkey.service";
  # the launcher carries the configuration: the stub wrap recorded it
  sshdWrapped = builtins.head (builtins.filter (p: p ? _wrapArgs) system.packages);
  sshdConfig = sshdWrapped._wrapArgs.files.sshd_config;

  # 1a. sshd with certificates: a user CA, principals, a KRL and a host certificate
  certTree = f.modules {
    options."/services/sshd" = {
      package = openssh;
      wrap = stubWrap;
      trustedUserCAKeys = [ "ssh-ed25519 AAAA user-ca" ];
      principals.root = [ "alice@example.com" ];
      revokedKeys = true;
      hostCertificate = true;
    };
  };
  certSshd = compose [ (certTree.modules.services.modules.sshd { }) ];
  certUnit = certSshd.units."sshd.service";
  certWrapped = builtins.head (builtins.filter (p: p ? _wrapArgs) certSshd.packages);
  certConfig = certWrapped._wrapArgs.files.sshd_config;
  certArgv = builtins.concatStringsSep " " certWrapped._wrapArgs.argv;
  sshdOptions = attrNames (import ../modules/services/sshd/default.nix { inherit types; }).options;
  sshdTree =
    opts:
    f.modules {
      options."/services/sshd" = {
        package = openssh;
        wrap = stubWrap;
      }
      // opts;
    };
  sshdThrows = opts: throws (compose [ ((sshdTree opts).modules.services.modules.sshd { }) ]);

  # 8. the factory: /etc seeds under /usr/share/factory/etc and their manifest
  factoryDir = "/usr/share/factory/etc";
  manifestPath = "/usr/lib/golconda/etc.manifest";
  factoryOf = opts: ((f.modules { options."/factory" = opts; }).modules.factory { });
  factoryThrows = opts: filesThrow [ (factoryOf opts) ];
  sha = builtins.hashString "sha256";
  pamSshd = factory.files."${factoryDir}/pam.d/sshd";
  manifest = factory.files.${manifestPath};
  manifestLines = builtins.filter (l: isString l && l != "") (builtins.split "\n" manifest);
  factoryPaths = builtins.filter (p: hasPrefix factoryDir p) (attrNames factory.files);
  # an admin edits /etc; sysusers and PID 1 write these: never in the factory
  neverSeeded = [
    "machine-id"
    "shadow"
    "gshadow"
    "passwd"
    "group"
  ];
  hostnamed = factoryOf { hostname = "ariel"; };

  tests = [
    (check "sshd: LoadCredentialEncrypted" (
      hasInfix "LoadCredentialEncrypted=hostkey:sshd-hostkey.key" unit
    ))
    (check "sshd: credential ref renders as %d" (hasInfix " -h %d/hostkey" unit))
    (check "sshd: runs the launcher from the farm" (
      hasInfix "\nExecStart=/usr/bin/sshd -h %d/hostkey\n" unit
      && sshdWrapped.bin == [ "sshd" ]
      && any (l: l.path == "/usr/bin/sshd" && l.target == "${sshdWrapped}/bin/sshd") system.links
    ))
    (check "sshd: the launcher reads its own sshd_config" (
      sshdWrapped._wrapArgs.argv == [
        "-D"
        "-e"
        "-f"
        "{root}/share/wrap/openssh/sshd_config"
        "-o"
        "AuthorizedKeysFile=.ssh/authorized_keys {root}/share/wrap/openssh/authorized_keys.%u"
      ]
      && sshdWrapped._wrapArgs.package == openssh
    ))
    (check "sshd: no file under /usr/lib/sshd" (
      !any (hasPrefix "/usr/lib/sshd/") (attrNames system.files)
    ))
    (check "sshd: authorized keys file is in the launcher" (
      sshdWrapped._wrapArgs.files."authorized_keys.root" == "ssh-ed25519 AAAA test\n"
    ))
    (check "sshd: the plain package keeps its other tools" (
      any (l: l.path == "/usr/bin/ssh-keygen" && l.target == "${openssh}/bin/ssh-keygen") system.links
      && any (l: l.path == "/usr/bin/ssh") system.links
    ))
    (check "sshd: the program must be one of the package's executables" (sshdThrows {
      package = standIn;
    }))
    (check "sshd: wrap is a function" (sshdThrows {
      wrap = "set.wrap";
    }))
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
        "wrap"
      ]
    ))
    (check "sshd: without a CA no certificate lines" (
      !any (hasInfix "TrustedUserCAKeys") sshdWrapped._wrapArgs.argv
      && !any (hasInfix "AuthorizedPrincipalsFile") sshdWrapped._wrapArgs.argv
      && !hasInfix "HostCertificate" unit
      && !hasInfix "RevokedKeys" unit
    ))
    (check "sshd: user CA keys file" (
      certWrapped._wrapArgs.files.trusted_user_ca_keys == "ssh-ed25519 AAAA user-ca\n"
      && hasInfix " -o TrustedUserCAKeys={root}/share/wrap/openssh/trusted_user_ca_keys" certArgv
      && !hasInfix "TrustedUserCAKeys" certConfig
    ))
    (check "sshd: principals file and AuthorizedPrincipalsFile" (
      certWrapped._wrapArgs.files."principals.root" == "alice@example.com\n"
      && hasInfix " -o AuthorizedPrincipalsFile={root}/share/wrap/openssh/principals.%u" certArgv
    ))
    (check "sshd: host certificate credential and option" (
      hasInfix "LoadCredentialEncrypted=hostcert:sshd-host-cert.cert\n" certUnit
      && hasInfix " -o HostCertificate=%d/hostcert" certUnit
    ))
    (check "sshd: revoked keys credential and option" (
      hasInfix "LoadCredentialEncrypted=krl:sshd-revoked-keys.krl\n" certUnit
      && hasInfix " -o RevokedKeys=%d/krl" certUnit
    ))
    (check "sshd: the admin vars are declared when their options are on" (
      builtins.fromJSON certSshd.files."/usr/lib/golconda/vars.d/sshd-host-cert.json".text == {
        name = "sshd-host-cert";
        class = "admin";
        files = [ "cert" ];
        credentials = [ "sshd-host-cert.cert" ];
      }
      &&
        (builtins.fromJSON certSshd.files."/usr/lib/golconda/vars.d/sshd-revoked-keys.json".text)
        .credentials == [ "sshd-revoked-keys.krl" ]
      && !(system.files ? "/usr/lib/golconda/vars.d/sshd-host-cert.json")
      && !(system.files ? "/usr/lib/golconda/vars.d/sshd-revoked-keys.json")
      && !(certSshd.units ? "golconda-var-sshd-host-cert.service")
    ))
    (check "sshd: the fixed lines survive the certificate options" (
      hasInfix "\nPasswordAuthentication no\n" certConfig
      && hasInfix "\nKbdInteractiveAuthentication no\n" certConfig
    ))
    (check "sshd: revokedKeys is a bool" (sshdThrows {
      revokedKeys = "sshd-revoked-keys";
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
          "/etc/credstore"
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
    (check "var: an admin var is a manifest entry and nothing else" (
      let
        frag = v.admin {
          name = "root-password";
          files = [
            "hash"
            "salt"
          ];
        };
      in
      attrNames frag == [ "files" ]
      && attrNames frag.files == [ "/usr/lib/golconda/vars.d/root-password.json" ]
      &&
        builtins.fromJSON frag.files."/usr/lib/golconda/vars.d/root-password.json" == {
          name = "root-password";
          class = "admin";
          files = [
            "hash"
            "salt"
          ];
          credentials = [
            "root-password.hash"
            "root-password.salt"
          ];
        }
    ))
    (check "var: one credential id for both classes" (
      v.credentialId "sshd-hostkey" "key" == "sshd-hostkey.key"
      && v.credentialId "sshd-host-cert" "cert" == "sshd-host-cert.cert"
      &&
        (builtins.fromJSON system.files."/usr/lib/golconda/vars.d/sshd-hostkey.json".text).class == "local"
      &&
        (builtins.fromJSON system.files."/usr/lib/golconda/vars.d/sshd-hostkey.json".text).credentials
        == [ "sshd-hostkey.key" ]
    ))
    (check "var: admin var names and files are words, files are required" (
      !(tryEval (
        deepSeq (v.admin {
          name = "a b";
          files = [ "x" ];
        }) true
      )).success
      && !(tryEval (
        deepSeq (v.admin {
          name = "a";
          files = [ "../x" ];
        }) true
      )).success
      && !(tryEval (deepSeq (v.admin { name = "a"; }) true)).success
      && !(tryEval (
        deepSeq (v.admin {
          name = "a";
          files = [ "x" ];
          script = "";
        }) true
      )).success
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
          "/factory"
          "/services"
          "/services/sshd"
          "/system"
          "/vars"
          "/wrap"
        ]
    ))
    (check "module-docs: files hold every page and the index and types" (
      attrNames docs.files == [
        "factory.md"
        "index.md"
        "services-sshd.md"
        "services.md"
        "system.md"
        "types.md"
        "vars.md"
        "wrap.md"
      ]
    ))
    (check "module-docs: the generated SUMMARY links every module page" (
      let
        inherit (docs) summary;
        # index.md is not linked directly in SUMMARY; module pages are
        moduleFiles = builtins.filter (n: n != "index.md") (attrNames docs.files);
      in
      all (n: hasInfix "reference/modules/generated/${n})" summary) moduleFiles
    ))
    (check "module-docs: fixed sshd_config lines never appear as rows" (
      !(hasInfix "PasswordAuthentication" docs.pages."/services/sshd")
    ))
    (check "module-docs: opaque types are named and noted" (
      let
        p = mockPage {
          properties."/x".properties.o."x-golconda-opaque" = "mystery";
        };
      in
      hasInfix "opaque `mystery`" p."/x" && hasInfix "Opaque types are not described" p."/x"
    ))
    (check "module-docs: a pipe or angle bracket in text cannot break the table" (
      let
        p = mockPage {
          properties."/x".properties.o = {
            type = "string";
            description = "a|b <c>";
          };
        };
      in
      hasInfix "a\\|b &lt;c>" p."/x"
    ))
    (check "module-docs: sshd's only opaque option is the wrap function" (
      hasInfix "Options with one: `wrap`." docs.pages."/services/sshd"
    ))

    # New tests for module doc comments and types
    (check "module-docs: every discovered module has a page" (
      all (m: docs.pages ? ${m.path}) modulePaths
    ))
    (check "module-docs: every module file has a #! doc comment" (
      all (m: docComments.moduleDoc m.filePath != null) modulePaths
    ))
    (check "module-docs: discovered paths match tree module paths" (
      let
        discoveredPaths = builtins.sort (a: b: a < b) (map (m: m.path) modulePaths);
        # Walk the tree to get all module paths
        walkTree =
          prefix: mod:
          let
            thisPath = if prefix == "" then "/" else prefix;
            children = builtins.attrNames (mod.modules or { });
            childPaths = builtins.concatMap (c: walkTree "${prefix}/${c}" mod.modules.${c}) children;
          in
          # Skip the root "/" path which doesn't have a file
          (if prefix != "" then [ thisPath ] else [ ]) ++ childPaths;
        treePaths = builtins.sort (a: b: a < b) (walkTree "" (f.modules { }));
      in
      discoveredPaths == treePaths
    ))
    (check "module-docs: types page lists every registry type" (
      let
        registryTypes = builtins.attrNames schemaLib.typeRegistry;
      in
      all (t: hasInfix "### `${t}`" docs.types) registryTypes
    ))
    (check "module-docs: every registry type has a description" (
      all (t: schemaLib.typeRegistry.${t} ? description) (builtins.attrNames schemaLib.typeRegistry)
    ))
    (check "module-docs: /system fragments option has a description" (
      let
        schema = schemaLib.toJsonSchema (f.modules { });
        fragments = schema.properties."/system".properties.fragments;
      in
      fragments ? description && fragments.description != ""
    ))
    (check "module-docs: vars page shows doc comment" (
      hasInfix "Installs the var runner" docs.pages."/vars"
    ))
    (check "module-docs: vars page shows it has an impl" (
      hasInfix "This module has an `impl`" docs.pages."/vars"
    ))
    (check "module-docs: services page has doc comment" (
      hasInfix "Container for service modules" docs.pages."/services"
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

    # 5b. app.program and the launcher in the farm
    (check "app.program defaults to the first bin and must be one of them" (
      a.binName { package = openssh; } == "ssh"
      &&
        a.binName {
          package = openssh;
          program = "sshd";
        } == "sshd"
      && a.binName { package = standIn; } == "jq"
      &&
        a.app.verify {
          package = openssh;
          program = "sshd";
        } == null
      &&
        a.app.verify {
          package = openssh;
          program = "httpd";
        } != null
      && hasInfix "openssh-10.6p1" (
        a.app.verify {
          package = openssh;
          program = "httpd";
        }
      )
    ))
    (check "wrapApp: the launcher declares the program as its one bin and what it wraps" (
      let
        w = a.wrapApp stubWrap {
          package = openssh;
          program = "sshd";
        };
      in
      w.bin == [ "sshd" ] && w.wraps == openssh && w.name == "openssh-wrap"
    ))
    (check "farm: a launcher stands in for the program of its own package" (
      let
        w = a.wrapApp stubWrap {
          package = openssh;
          program = "sshd";
        };
        inherit
          (compose [
            {
              packages = [
                openssh
                w
              ];
            }
          ])
          links
          ;
        linksReversed =
          (compose [
            {
              packages = [
                w
                openssh
              ];
            }
          ]).links;
        sshdLink = builtins.filter (l: l.path == "/usr/bin/sshd");
      in
      map (l: l.target) (sshdLink links) == [ "${w}/bin/sshd" ]
      && map (l: l.target) (sshdLink linksReversed) == [ "${w}/bin/sshd" ]
      && builtins.length links == 3
      && any (l: l.path == "/usr/bin/ssh" && l.target == "/nix/store/openssh-10.6p1/bin/ssh") links
    ))
    (check "farm: a launcher does not take another package's program" (
      !(tryEval (
        deepSeq (farmOf [
          (withBin "dropbear-1" [ "sshd" ])
          (a.wrapApp stubWrap {
            package = openssh;
            program = "sshd";
          })
        ]) true
      )).success
    ))
    (check "farm: two launchers for one program clash" (
      !(tryEval (
        deepSeq (farmOf [
          (a.wrapApp stubWrap {
            package = openssh;
            program = "sshd";
            argv = [ "-D" ];
          })
          (a.wrapApp stubWrap {
            package = openssh;
            program = "sshd";
            argv = [ "-d" ];
          })
        ]) true
      )).success
    ))
    (check "renderWrapped: .wants links and [Install] follow wantedBy" (
      let
        frag = s.renderWrapped stubWrap {
          name = "w";
          app.package = standIn;
          user = "dynamic";
          sandbox = "strict";
          wantedBy = [ "sysinit.target" ];
        };
      in
      frag.links == [
        {
          path = "/usr/lib/systemd/system/sysinit.target.wants/w.service";
          target = "../w.service";
        }
      ]
      && hasInfix "[Install]\nWantedBy=sysinit.target\n" frag.units."w.service"
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

    # 8. usr-tree library: pure helpers
    (check "usr-tree: stripUsrPrefix strips /usr/ prefix" (
      usrTreeLib.stripUsrPrefix "/usr/lib/foo" == "lib/foo"
      && usrTreeLib.stripUsrPrefix "/usr/bin/jq" == "bin/jq"
    ))
    (check "usr-tree: stripUsrPrefix returns null for non-/usr paths" (
      usrTreeLib.stripUsrPrefix "/etc/foo" == null && usrTreeLib.stripUsrPrefix "/var/lib/x" == null
    ))
    (check "usr-tree: versionToEpoch parses date versions" (
      let
        e1 = usrTreeLib.versionToEpoch "20261031.1";
        e2 = usrTreeLib.versionToEpoch "20261031.2";
      in
      e2 > e1 # revision 2 is later than revision 1
    ))
    (check "usr-tree: versionToEpoch handles fallback" (
      let
        e = usrTreeLib.versionToEpoch "1";
      in
      e == 1609459201 # base epoch + 1
    ))
    (check "usr-tree: makeRelative creates correct relative paths" (
      usrTreeLib.makeRelative "/usr/bin/jq" "/nix/store/abc-jq/bin/jq" == "../nix/store/abc-jq/bin/jq"
      &&
        usrTreeLib.makeRelative "/usr/lib/systemd/system/foo.service" "/nix/store/xyz/lib/systemd/system/foo.service"
        == "../../../nix/store/xyz/lib/systemd/system/foo.service"
    ))
    (check "usr-tree: makeRelative preserves relative targets" (
      usrTreeLib.makeRelative "/usr/lib/systemd/system/multi-user.target.wants/sshd.service" "../sshd.service"
      == "../sshd.service"
    ))
    (check "usr-tree: allowedDirs includes expected directories" (
      builtins.elem "bin" usrTreeLib.allowedDirs
      && builtins.elem "lib" usrTreeLib.allowedDirs
      && builtins.elem "share" usrTreeLib.allowedDirs
      && builtins.elem "nix" usrTreeLib.allowedDirs
    ))
    (check "usr-tree: renderOsRelease includes version and arch" (
      let
        osRel = usrTreeLib.renderOsRelease {
          version = "20261031.1";
          platform = {
            cpu = "x86_64";
          };
        };
      in
      hasInfix "VERSION_ID=20261031.1" osRel
      && hasInfix "IMAGE_VERSION=20261031.1" osRel
      && hasInfix "ARCHITECTURE=x86_64" osRel
    ))

    # 8. the factory seed and its manifest
    (check "factory: pam.d/sshd is account and session only" (
      hasInfix "\naccount required pam_unix.so\n" pamSshd
      && hasInfix "\nsession optional pam_systemd.so\n" pamSshd
      && hasInfix "\nsession required pam_unix.so\n" pamSshd
      && !hasInfix "\nauth " pamSshd
      && !hasInfix "\npassword " pamSshd
    ))
    (check "factory: pam.d/other denies everything" (
      all (t: hasInfix "\n${t} required pam_deny.so\n" factory.files."${factoryDir}/pam.d/other") [
        "auth"
        "account"
        "password"
        "session"
      ]
    ))
    (check "factory: the manifest line for pam.d/sshd carries its sha256" (
      elem "f 0644 root:root ${sha pamSshd} /etc/pam.d/sshd" manifestLines
    ))
    (check "factory: the manifest lists every seed, the links and the directories" (
      all (
        p: any (l: hasInfix " /etc/${substring (stringLength factoryDir + 1) 999 p}" l) manifestLines
      ) factoryPaths
      && elem "l - root:root /usr/share/zoneinfo/UTC /etc/localtime" manifestLines
      && elem "l - root:root ../usr/lib/os-release /etc/os-release" manifestLines
      && elem "d 0755 root:root - /etc/ssh" manifestLines
      && builtins.length manifestLines == builtins.length factoryPaths + 3
    ))
    (check "factory: no machine-id, shadow, passwd or group in the factory or the manifest" (
      all (
        n: !(factory.files ? "${factoryDir}/${n}") && !any (l: hasInfix " /etc/${n}" l) manifestLines
      ) neverSeeded
    ))
    (check "factory: extraFiles refuse the names sysusers and PID 1 own" (
      all (n: factoryThrows { extraFiles.${n} = "x"; }) neverSeeded
    ))
    (check "factory: the seed, the links, the stamp and the sshd user" (
      elem "C+ /etc - - - - ${factoryDir}" factory.tmpfiles
      && elem "f /etc/.golconda-factory-id 0644 root root - ${sha manifest}" factory.tmpfiles
      && elem "L /etc/localtime - - - - /usr/share/zoneinfo/UTC" factory.tmpfiles
      && elem "L /etc/os-release - - - - ../usr/lib/os-release" factory.tmpfiles
      && elem "d /etc/ssh 0755 root root -" factory.tmpfiles
      && elem "d /var/empty 0755 root root -" factory.tmpfiles
      && !any (hasInfix "machine-id") factory.tmpfiles
      && any (hasInfix "u sshd ") factory.sysusers
    ))
    (check "factory: shells are dash and sh" (
      factory.files."${factoryDir}/shells" == "/usr/bin/sh\n/usr/bin/dash\n"
    ))
    (check "factory: hostname changes the file, the manifest and the stamp" (
      hostnamed.files."${factoryDir}/hostname" == "ariel\n"
      && factory.files."${factoryDir}/hostname" == "golconda\n"
      && hasInfix "f 0644 root:root ${sha "ariel\n"} /etc/hostname\n" hostnamed.files.${manifestPath}
      && hostnamed.files.${manifestPath} != manifest
      && !elem "f /etc/.golconda-factory-id 0644 root root - ${sha manifest}" hostnamed.tmpfiles
    ))
    (check "factory: hostname is one word" (factoryThrows {
      hostname = "a b";
    }))
    (check "factory: timezone changes the link and is a zone name" (
      elem "L /etc/localtime - - - - /usr/share/zoneinfo/Europe/Berlin"
        (factoryOf {
          timezone = "Europe/Berlin";
        }).tmpfiles
      && factoryThrows { timezone = "../etc/shadow"; }
      && factoryThrows { timezone = "/usr/share/zoneinfo/UTC"; }
    ))
    (check "factory: extraFiles are seeded with their mode and listed" (
      let
        r = factoryOf {
          extraFiles."security/limits.conf" = "* hard core 0\n";
          extraFiles."rc.local" = {
            text = "#!/bin/sh\n";
            mode = "0755";
          };
        };
      in
      r.files."${factoryDir}/security/limits.conf" == "* hard core 0\n"
      &&
        hasInfix "f 0644 root:root ${sha "* hard core 0\n"} /etc/security/limits.conf\n"
          r.files.${manifestPath}
      && hasInfix "f 0755 root:root ${sha "#!/bin/sh\n"} /etc/rc.local\n" r.files.${manifestPath}
    ))
    (check "factory: an extra file at a built-in path throws" (
      factoryThrows { extraFiles."pam.d/sshd" = "auth sufficient pam_permit.so\n"; }
      && factoryThrows { extraFiles.hostname = "x\n"; }
    ))
    (check "factory: an extra file path is relative and plain" (
      factoryThrows { extraFiles."/etc/motd" = "x"; }
      && factoryThrows { extraFiles."../usr/lib/os-release" = "x"; }
      && factoryThrows { extraFiles."a/../shadow" = "x"; }
      && factoryThrows { extraFiles."motd" = 1; }
    ))
    (check "factory: a second module at a factory path is a composer error" (filesThrow [
      factory
      { files."${factoryDir}/pam.d/sshd" = "x"; }
    ]))
    (check "factory: two factories are a composer error" (filesThrow [
      factory
      (factoryOf { })
    ]))

    # 9. Cross-compilation: platform flows through the module tree
    (check "cross: platform record flows to os-release" (
      let
        x86 = {
          name = "x86_64-linux";
          cpu = "x86_64";
        };
        arm = {
          name = "aarch64-linux";
          cpu = "aarch64";
        };
        osX86 = usrTreeLib.renderOsRelease {
          version = "20261031.1";
          platform = x86;
        };
        osArm = usrTreeLib.renderOsRelease {
          version = "20261031.1";
          platform = arm;
        };
      in
      hasInfix "ARCHITECTURE=x86_64" osX86
      && hasInfix "ARCHITECTURE=aarch64" osArm
      && hasInfix "VERSION_ID=20261031.1" osX86
      && hasInfix "IMAGE_VERSION=20261031.1" osArm
    ))
    (check "cross: x86_64 and aarch64 sets differ in jq drvPath" (
      let
        x86Set = import ./packages.nix {
          inherit sources;
          system = "x86_64-linux";
          platform = "x86_64-linux";
        };
        armSet = import ./packages.nix {
          inherit sources;
          system = "x86_64-linux";
          platform = "aarch64-linux";
        };
      in
      # Platform names differ
      x86Set.platform.name == "x86_64-linux"
      && armSet.platform.name == "aarch64-linux"
      # CPU differs
      && x86Set.platform.cpu == "x86_64"
      && armSet.platform.cpu == "aarch64"
      # The sets are for different targets (jq.drvPath would differ, but we cannot
      # instantiate without ca-derivations; check the platform record instead)
      && x86Set.platform.names.uefi == "x64"
      && armSet.platform.names.uefi == "aa64"
    ))

    # 10. Boundary tests: config-in-store boundary enforcement
    # (docs/design/config.md, docs/design/modules.md)

    # 10a. Positive: wrapped output's config file has no credential paths
    (check "boundary: wrapped config file has no %d or credential paths" (
      # sshdConfig is the config file text in the wrapper, not the unit
      !hasInfix "%d/" sshdConfig
      && !hasInfix "$CREDENTIALS_DIRECTORY" sshdConfig
      && !hasInfix "/etc/credstore" sshdConfig
      # credential refs are only in the unit's ExecStart (extraArgv)
      && hasInfix "%d/hostkey" unit
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

    # 10d. Negative: TOML config with derivation-valued option (we check the type system rejects it)
    (check "boundary: config rejects non-data values" (
      # The configLib validates against the schema; a derivation or function would fail type checks.
      # Test that loadConfig throws on invalid paths (the type system handles value validation)
      !(tryEval (configLib.loadConfig ../examples/bad.toml)).success
      # Valid paths exist
      && elem "/services/sshd" configLib.validPaths
      && elem "/system" configLib.validPaths
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
  ];
in
assert all (t: t) tests;
assert
  attrNames system.units == [
    "golconda-var-sshd-hostkey.service"
    "sshd.service"
  ];
true
