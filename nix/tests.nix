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
  a = import ../modules/lib/app.nix { inherit types; };
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
  ];
in
assert all (t: t) tests;
assert
  attrNames system.units == [
    "golconda-var-sshd-hostkey.service"
    "sshd.service"
  ];
true
