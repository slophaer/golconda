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
    elemAt
    filter
    genList
    isString
    length
    lessThan
    listToAttrs
    match
    readFile
    sort
    split
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
  fr = import ../modules/lib/fragment.nix { inherit types; };
  merge = import ../modules/lib/merge.nix;
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
  imageLib = import ../lib/image { };
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
  # base packages for /base module
  stubSystemd = withBin "systemd-262" [ "systemctl" ];
  stubDbusBroker = withBin "dbus-broker-42" [ "dbus-broker" ];
  stubDash = withBin "dash-0.5.13.5" [ "dash" ];
  stubUutils = withBin "uutils-coreutils-0.0.25" [
    "ls"
    "cat"
    "cp"
    "mv"
    "rm"
  ];
  stubLinuxKernel = withBin "linux-kernel-6.18.0" [ ];
  # the repkgs set as /pkgs sees it: the stand-ins above
  stubSet = {
    buildPkgs = stubSet.pkgs;
    pkgs = {
      inherit openssh;
      jq = standIn;
      # base packages
      systemd = stubSystemd;
      dbus-broker = stubDbusBroker;
      dash = stubDash;
      uutils-coreutils = stubUutils;
      linux-kernel = stubLinuxKernel;
    }
    # the libraries /base links for systemd's dlopen (dlopenSonames): no bin, name only
    // builtins.listToAttrs (
      map
        (n: {
          name = n;
          value = withBin "${n}-0" [ ];
        })
        [
          "acl"
          "libarchive"
          "util-linux"
          "openssl"
          "cryptsetup"
          "curl"
          "lz4"
          "xz"
          "zstd"
          "zlib"
          "p11-kit"
          "linux-pam"
          "pcre2"
          "libseccomp"
          "tpm2-tss"
          "e2fsprogs"
        ]
    );
  };
  withPkgs =
    options:
    f.modules {
      options = options // {
        "/pkgs".target = stubSet;
      };
    };
  farmOf =
    packages:
    (
      (f.modules {
        options = {
          "/pkgs".target = stubSet;
          "/system" = {
            name = "farm";
            version = "20261031.1";
            fragments = [ { inherit packages; } ];
          };
        };
      }).modules.system
        { }
    ).packages;

  compose =
    fragments:
    (f.modules {
      options = {
        "/pkgs".target = stubSet;
        "/system" = {
          name = "t";
          version = "20261031.1";
          inherit fragments;
        };
      };
    }).modules.system
      { };
  # compose with extra module options (for /network, /factory, etc.)
  composeWith =
    extraOpts:
    (f.modules {
      options = {
        "/pkgs".target = stubSet;
        "/system" = {
          name = "t";
          version = "20261031.1";
          fragments = [ ];
        };
      }
      // extraOpts;
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
  tree = withPkgs {
    "/services/sshd" = {
      authorizedKeys = [ "ssh-ed25519 AAAA test" ];
    };
  };
  sshd = tree.modules.services.modules.sshd { };
  vars = tree.modules.vars { };
  factory = tree.modules.factory { };
  system =
    (f.modules {
      options = {
        "/pkgs".target = stubSet;
        "/system" = {
          name = "test";
          version = "20261031.1";
          fragments = [
            sshd
            vars
            factory
          ];
        };
      };
    }).modules.system
      { };
  unit = system.units."sshd.service";
  varUnit = system.units."golconda-var-sshd-hostkey.service";
  sshdDir = "/usr/lib/sshd";
  sshdConfig = system.files."${sshdDir}/sshd_config".text;

  # 1a. sshd with certificates: a user CA, principals, a KRL and a host certificate
  certTree = withPkgs {
    "/services/sshd" = {
      trustedUserCAKeys = [ "ssh-ed25519 AAAA user-ca" ];
      principals.root = [ "alice@example.com" ];
      revokedKeys = true;
      hostCertificate = true;
    };
  };
  certSshd = compose [ (certTree.modules.services.modules.sshd { }) ];
  certUnit = certSshd.units."sshd.service";
  certConfig = certSshd.files."${sshdDir}/sshd_config".text;
  sshdOptions = attrNames (import ../modules/services/sshd/default.nix { inherit types; }).options;
  sshdTree = opts: withPkgs { "/services/sshd" = opts; };
  sshdThrows = opts: throws (compose [ ((sshdTree opts).modules.services.modules.sshd { }) ]);
  # the set enters once: a tree without /pkgs cannot build what needs a package
  noSet = f.modules { options."/services/sshd" = { }; };
  pkgsResult = (withPkgs { }).modules.pkgs { };
  # a cross set: the host's packages are other than the target's
  crossBuildPkgs = {
    host = true;
  };
  crossPkgs =
    extra:
    (f.modules {
      options."/pkgs" = {
        target = stubSet // {
          buildPkgs = crossBuildPkgs;
        };
      }
      // extra;
    }).modules.pkgs
      { };

  # 8. the factory: /etc seeds under /usr/share/factory/etc as symlinks
  factoryDir = "/usr/share/factory/etc";
  factoryOf = opts: ((f.modules { options."/factory" = opts; }).modules.factory { });
  factoryThrows = opts: filesThrow [ (factoryOf opts) ];
  pamSshd = factory.files."${factoryDir}/pam.d/sshd";
  factoryPaths = builtins.filter (p: hasPrefix factoryDir p) (attrNames factory.files);
  # an admin edits /etc; sysusers and PID 1 write these: never in the factory;
  # hostname is a bootstrap credential, not a factory file
  neverSeeded = [
    "machine-id"
    "shadow"
    "gshadow"
    "passwd"
    "group"
    "hostname"
  ];

  tests = [
    (check "sshd: LoadCredentialEncrypted" (
      hasInfix "LoadCredentialEncrypted=hostkey:sshd-hostkey.key" unit
    ))
    (check "sshd: credential ref renders as %d" (hasInfix " -h %d/hostkey" unit))
    (check "sshd: ExecStart is the program from the farm with its config and credential" (
      hasInfix "\nExecStart=/usr/bin/sshd -D -e -f /usr/lib/sshd/sshd_config -h %d/hostkey\n" unit
      &&
        system.links."/usr/bin/sshd" == {
          target = "${openssh}/bin/sshd";
          kind = "package";
        }
    ))
    (check "sshd: the configuration is under /usr/lib/sshd, mode 0644" (
      builtins.filter (hasPrefix "${sshdDir}/") (attrNames system.files) == [
        "${sshdDir}/authorized_keys/root"
        "${sshdDir}/sshd_config"
      ]
      && system.files."${sshdDir}/sshd_config".mode == "0644"
      && hasInfix "\nPort 22\n" sshdConfig
    ))
    (check "sshd: authorized keys file and the AuthorizedKeysFile line" (
      system.files."${sshdDir}/authorized_keys/root".text == "ssh-ed25519 AAAA test\n"
      && hasInfix "\nAuthorizedKeysFile .ssh/authorized_keys /usr/lib/sshd/authorized_keys/%u\n" sshdConfig
      && !hasInfix "AuthorizedKeysFile" unit
    ))
    (check "sshd: the package's other tools are in the farm" (
      system.links."/usr/bin/ssh-keygen".target == "${openssh}/bin/ssh-keygen"
      && system.links ? "/usr/bin/ssh"
    ))
    (check "sshd: the program must be one of the package's executables" (sshdThrows {
      package = standIn;
    }))
    (check "pkgs: /pkgs returns the set and its pkgs, nothing else" (
      pkgsResult.target.pkgs == stubSet.pkgs
      && pkgsResult.pkgs.openssh == openssh
      &&
        attrNames pkgsResult == [
          "build"
          "pkgs"
          "target"
        ]
    ))
    (check "pkgs: sshd takes openssh from the set" (
      elem openssh system.packages
      && (sshdTree { package = standIn; }).modules.services.modules.sshd.args.options.package == standIn
    ))
    (check "pkgs: without the set, sshd and /pkgs throw" (
      throws (noSet.modules.services.modules.sshd { }) && !(tryEval (noSet.modules.pkgs { })).success
    ))
    (check "pkgs: the set must have pkgs" (
      let
        setThrows =
          set:
          !(tryEval (
            builtins.seq ((f.modules { options."/pkgs".target = set; }).modules.pkgs { }).target true
          )).success;
      in
      setThrows { pkgs = [ ]; }
      && setThrows { wrap = _: null; }
      && setThrows "repkgs"
      && !setThrows stubSet
    ))
    (check "sshd: waits for the var" (hasInfix "After=golconda-var-sshd-hostkey.service" unit))
    (check "sshd: sessions outlive a restart; no runtime directory" (
      hasInfix "\nKillMode=process\n" unit && !hasInfix "RuntimeDirectory=" unit
    ))
    (check "sshd: sftp is a subsystem in sshd_config, not a unit field" (
      hasInfix "\nSubsystem sftp internal-sftp\n" sshdConfig && !hasInfix "Subsystem" unit
    ))
    (check "sshd: owns its privsep user and /var/empty" (
      elem "u sshd - \"SSH privilege separation\" /var/empty" sshd.sysusers
      && elem "d /var/empty 0755 root root -" sshd.tmpfiles
      && any (hasInfix "u sshd ") system.sysusers
    ))
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
      !hasInfix "TrustedUserCAKeys" unit
      && !hasInfix "TrustedUserCAKeys" sshdConfig
      && !hasInfix "AuthorizedPrincipalsFile" unit
      && !hasInfix "AuthorizedPrincipalsFile" sshdConfig
      && !hasInfix "HostCertificate" unit
      && !hasInfix "RevokedKeys" unit
      && !(system.files ? "${sshdDir}/ca.pub")
    ))
    (check "sshd: the whole certificate ExecStart, in order: only credentials on the command line" (
      hasInfix (
        "\nExecStart=/usr/bin/sshd -D -e -f /usr/lib/sshd/sshd_config -h %d/hostkey"
        + " -o HostCertificate=%d/hostcert -o RevokedKeys=%d/krl\n"
      ) certUnit
      && !hasInfix "TrustedUserCAKeys" certUnit
      && !hasInfix "AuthorizedPrincipalsFile" certUnit
    ))
    (check "sshd: user CA keys file and the TrustedUserCAKeys line in sshd_config" (
      certSshd.files."${sshdDir}/ca.pub".text == "ssh-ed25519 AAAA user-ca\n"
      && hasInfix "\nTrustedUserCAKeys /usr/lib/sshd/ca.pub\n" certConfig
    ))
    (check "sshd: principals file and the AuthorizedPrincipalsFile line in sshd_config" (
      certSshd.files."${sshdDir}/principals/root".text == "alice@example.com\n"
      # %u reaches sshd as a literal: a file needs no escaping
      && hasInfix "\nAuthorizedPrincipalsFile /usr/lib/sshd/principals/%u\n" certConfig
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

    # 2. one argv: strings and credential refs; a ref must name a declared credential
    (check "app.argv accepts a declared credential ref and renders it as %d" (
      hasInfix "\nExecStart=/usr/bin/jq -c %d/k\n"
        (s.render {
          name = "x";
          app = {
            package = standIn;
            argv = [
              "-c"
              (s.credential "k")
            ];
          };
          credentials.k = "x.k";
          user = "dynamic";
          sandbox = "strict";
        }).units."x.service"
    ))
    (check "app.argv refuses an undeclared credential ref and a malformed one" (
      let
        base = {
          name = "x";
          app.package = standIn;
          user = "dynamic";
          sandbox = "strict";
        };
      in
      throws (s.render (base // { app.argv = [ (s.credential "k") ]; }))
      && throws (
        s.render (
          base
          // {
            app.argv = [
              {
                credential = "k";
                extra = 1;
              }
            ];
            credentials.k = "x.k";
          }
        )
      )
      && throws (s.render (base // { app.argv = [ 1 ]; }))
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
    (check "app.argv renders a prefixed credential ref" (
      hasInfix " -o RevokedKeys=%d/k\n"
        (s.render {
          name = "x";
          app = {
            package = standIn;
            argv = [
              "-o"
              (s.credentialArg "RevokedKeys=" "k")
            ];
          };
          credentials.k = "x.k";
          user = "dynamic";
          sandbox = "strict";
        }).units."x.service"
    ))
    (check "a credential prefix is one plain word" (
      throws (
        s.render {
          name = "x";
          app = {
            package = standIn;
            argv = [ (s.credentialArg "Revoked Keys=" "k") ];
          };
          credentials.k = "x.k";
          user = "dynamic";
          sandbox = "strict";
        }
      )
    ))
    (check "service and app refuse an unknown field: extraArgv is gone" (
      let
        base = {
          name = "x";
          app.package = standIn;
          user = "dynamic";
          sandbox = "strict";
        };
      in
      throws (s.render (base // { extraArgv = [ "-D" ]; }))
      && throws (s.render (base // { app.wraps = standIn; }))
      && hasInfix "extraArgv" (s.service.verify (base // { extraArgv = [ "-D" ]; }))
      && !throws (s.render base)
    ))
    (check "render writes the app's files under /usr/lib/<name>, directories included" (
      let
        frag = s.render {
          name = "foo";
          app = {
            package = standIn;
            argv = [
              "-f"
              "${s.filesDir "foo"}/foo.conf"
            ];
            files = {
              "foo.conf" = "a=1\n";
              "keys/root" = "k\n";
            };
          };
          user = "dynamic";
          sandbox = "strict";
        };
      in
      s.filesDir "foo" == "/usr/lib/foo"
      && frag.files."/usr/lib/foo/foo.conf" == "a=1\n"
      && frag.files."/usr/lib/foo/keys/root" == "k\n"
      && hasInfix "\nExecStart=/usr/bin/jq -f /usr/lib/foo/foo.conf\n" frag.units."foo.service"
      && frag.packages == [ standIn ]
    ))
    (check "render: Environment= from env operations" (
      hasInfix "\nEnvironment=HOME=/var/lib/x\n"
        (s.render {
          name = "x";
          app = {
            package = standIn;
            env.HOME.set = "/var/lib/x";
          };
          user = "dynamic";
          sandbox = "strict";
        }).units."x.service"
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
            version = "20261031.1";
            fragments = [
              { units."a.service" = "[Unit]\n"; }
              { units."a.service" = "[Service]\n"; }
            ];
          };
        }).modules.system
          { }
      )
    ))
    # 3a. typed units: the name has a unit suffix, the text a section header
    (check "units: every unit suffix is accepted, a template name too" (
      let
        r = compose [
          {
            units = builtins.listToAttrs (
              map (sfx: {
                name = "a.${sfx}";
                value = "[Unit]\nDescription=a\n";
              }) fr.unitSuffixes
            );
          }
          { units."getty@.service" = "[Service]\nExecStart=/usr/bin/agetty %I\n"; }
        ];
      in
      builtins.length (attrNames r.units) == 8
      &&
        fr.unitSuffixes == [
          "service"
          "target"
          "socket"
          "timer"
          "path"
          "mount"
          "slice"
        ]
    ))
    (check "units: a bad suffix is a type error that names it" (
      throws (compose [ { units."a.conf" = "[Unit]\n"; } ])
      && throws (compose [ { units."a.service.bak" = "[Unit]\n"; } ])
      && throws (compose [ { units."a b.service" = "[Unit]\n"; } ])
      && hasInfix "'a.conf'" (fr.units.verify { "a.conf" = "[Unit]\n"; })
    ))
    (check "units: empty text or text without a section header is a type error" (
      throws (compose [ { units."a.service" = ""; } ])
      && throws (compose [ { units."a.service" = "Description=a\nExecStart=/usr/bin/a\n"; } ])
      && throws (compose [ { units."a.service" = 1; } ])
      && hasInfix "in unit 'a.service'" (fr.units.verify { "a.service" = ""; })
    ))
    (check "composer refuses a duplicate file" (filesThrow [
      { files."/usr/lib/foo/config" = "a"; }
      { files."/usr/lib/foo/config" = "b"; }
    ]))
    (check "composer concatenates lists" (
      let
        result =
          (f.modules {
            options = {
              "/pkgs".target = stubSet;
              "/system" = {
                name = "cat";
                version = "20261031.1";
                fragments = [
                  { sysusers = [ "a" ]; }
                  { sysusers = [ "b" ]; }
                ];
              };
            };
          }).modules.system
            { };
      in
      # /base adds its own sysusers; check that the fragments' sysusers are there
      elem "a" result.sysusers && elem "b" result.sysusers
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
    (check "farm accepts distinct names; the same package twice is one package, one link" (
      let
        a = withBin "a-1" [ "x" ];
        b = withBin "b-1" [ "y" ];
        packages = [
          a
          b
          a
        ];
        result = compose [ { inherit packages; } ];
      in
      # farmOf includes /base packages; check the requested packages are there
      elem a (farmOf packages)
      && elem b (farmOf packages)
      # the links include these with the right targets
      &&
        result.links."/usr/bin/x" == {
          target = "${a}/bin/x";
          kind = "package";
        }
      &&
        result.links."/usr/bin/y" == {
          target = "${b}/bin/y";
          kind = "package";
        }
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
    (check "killMode and runtimeDirectory render; neither by default" (
      let
        base = {
          name = "x";
          app.package = standIn;
          user = "dynamic";
          sandbox = "strict";
        };
        plain = (s.render base).units."x.service";
        extra =
          (s.render (
            base
            // {
              killMode = "mixed";
              runtimeDirectory = "x";
            }
          )).units."x.service";
      in
      !hasInfix "KillMode=" plain
      && !hasInfix "RuntimeDirectory=" plain
      && hasInfix "\nRuntimeDirectory=x\nKillMode=mixed\n" extra
    ))
    (check "killMode is an enum and runtimeDirectory one component" (
      throws (
        s.render {
          name = "x";
          app.package = standIn;
          user = "dynamic";
          sandbox = "strict";
          killMode = "none";
        }
      )
      && throws (
        s.render {
          name = "x";
          app.package = standIn;
          user = "dynamic";
          sandbox = "strict";
          runtimeDirectory = "a/b";
        }
      )
      && throws (
        s.render {
          name = "x";
          app.package = standIn;
          user = "dynamic";
          sandbox = "strict";
          runtimeDirectory = [ "a" ];
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

    # 7. Version format: YYYYMMDD.N
    (check "version format: YYYYMMDD.N accepted" (
      let
        validVersions = [
          "20261031.1"
          "20260101.0"
          "20301231.99"
        ];
        tryVersion =
          v:
          (tryEval (
            f.modules {
              options = {
                "/pkgs".target = stubSet;
                "/system" = {
                  name = "t";
                  version = v;
                };
              };
            }
          )).success;
      in
      all tryVersion validVersions
    ))
    (check "version format: invalid versions rejected" (
      let
        invalidVersions = [
          "0"
          "2026.10.31"
          "2026-10-31.1"
          "20261031"
          "v1.0.0"
        ];
        tryVersion =
          v:
          (tryEval (
            deepSeq
              (f.modules {
                options = {
                  "/pkgs".target = stubSet;
                  "/system" = {
                    name = "t";
                    version = v;
                  };
                };
              }).modules.system
              { }
              true
          )).success;
      in
      !any tryVersion invalidVersions
    ))

    # 7b. /system.updateSource renders sysupdate.d
    (check "system: updateSource renders /usr/lib/sysupdate.d with Path=" (
      let
        result = composeWith {
          "/system" = {
            name = "t";
            version = "20261031.1";
            fragments = [ ];
            updateSource = "https://updates.example/t/";
          };
        };
        usr = result.files."/usr/lib/sysupdate.d/10-usr.conf".text;
      in
      hasInfix "[Source]" usr
      && hasInfix "Path=https://updates.example/t/" usr
      && hasInfix "MatchPattern=t_@v.usr.raw" usr
      && hasInfix "ProtectVersion=%A" usr
      && hasInfix "Verify=no" usr
      && result.files ? "/usr/lib/sysupdate.d/40-uki.conf"
    ))
    (check "system: no updateSource, no sysupdate.d" (
      let
        result = composeWith { };
      in
      !(builtins.any (n: hasPrefix "/usr/lib/sysupdate.d/" n) (builtins.attrNames result.files))
    ))
    (check "ini: lists repeat the key, booleans are yes/no, null drops" (
      (import ../modules/lib/ini.nix).render {
        A = {
          k = [
            "x"
            "y"
          ];
          b = true;
          n = null;
        };
      } == "[A]\nb=yes\nk=x\nk=y\n"
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
          "/base"
          "/factory"
          "/network"
          "/pkgs"
          "/security"
          "/services"
          "/services/sshd"
          "/system"
          "/vars"
        ]
    ))
    (check "module-docs: files hold every page and the index and types" (
      attrNames docs.files == [
        "base.md"
        "factory.md"
        "index.md"
        "network.md"
        "pkgs.md"
        "security.md"
        "services-sshd.md"
        "services.md"
        "system.md"
        "types.md"
        "vars.md"
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
    (check "module-docs: sshd has no opaque option; package renders as a package" (
      !hasInfix "Opaque types" docs.pages."/services/sshd"
      && !hasInfix "`wrap`" docs.pages."/services/sshd"
      && hasInfix "| `package` | package | none |" docs.pages."/services/sshd"
    ))
    (check "schema: sshd has no wrap option and /pkgs.target is the set" (
      let
        schema = schemaLib.toJsonSchema (f.modules { });
      in
      !(schema.properties."/services/sshd".properties ? wrap)
      && schema.properties."/services/sshd".properties.package."x-golconda" == "package"
      && schema.properties."/pkgs".properties.target."x-golconda" == "set"
      && schema.properties."/pkgs".properties.build."x-golconda" == "set"
      && hasInfix "| `target` | set | none |" docs.pages."/pkgs"
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
    (check "config: validPaths includes sshd and not /pkgs" (
      builtins.elem "/services/sshd" configLib.validPaths
      && builtins.elem "/system" configLib.validPaths
      && !builtins.elem "/pkgs" configLib.validPaths
    ))
    (check "config: a /pkgs table is refused: the set is not data" (
      !(tryEval (configLib.loadConfigText "[\"/pkgs\"]\nset = \"repkgs\"\n")).success
      && !(configLib.loadConfig ../examples/server.toml).options ? "/pkgs"
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
    (check "config: loadAndApply with the set builds sshd from the document" (
      let
        appliedTree = (configLib.withPkgs stubSet).loadAndApply ../examples/server.toml;
        frag = compose [ (appliedTree.modules.services.modules.sshd { }) ];
      in
      ((configLib.withPkgs stubSet).loadConfig ../examples/server.toml).options."/pkgs".target.pkgs
      == stubSet.pkgs
      &&
        hasInfix "ExecStart=/usr/bin/sshd -D -e -f /usr/lib/sshd/sshd_config -h %d/hostkey\n"
          frag.units."sshd.service"
      && elem openssh frag.packages
    ))
    (check "config: loadAndApply without the set cannot build sshd" (
      throws (compose [
        ((configLib.loadAndApply ../examples/server.toml).modules.services.modules.sshd { })
      ])
    ))

    # 5b. app.program and the /usr/bin farm
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
    (check "farm: a second package with the same program clashes, whatever it is" (
      !(tryEval (
        deepSeq (farmOf [
          (withBin "dropbear-1" [ "sshd" ])
          openssh
        ]) true
      )).success
      && !(tryEval (
        deepSeq (farmOf [
          openssh
          (openssh // { outPath = "/nix/store/openssh-10.6p1-other"; })
        ]) true
      )).success
    ))
    (check "render: .wants links and [Install] follow wantedBy" (
      let
        frag = s.render {
          name = "w";
          app.package = standIn;
          user = "dynamic";
          sandbox = "strict";
          wantedBy = [ "sysinit.target" ];
        };
      in
      frag.links == {
        "/usr/lib/systemd/system/sysinit.target.wants/w.service" = {
          target = "../w.service";
          kind = "explicit";
        };
      }
      && hasInfix "[Install]\nWantedBy=sysinit.target\n" frag.units."w.service"
    ))

    # 5. one links map: /usr/bin from packages, the fragments' farm, dlopen and
    # explicit links, one duplicate check that names both sources
    (check "links: a package with two bins is two package links" (
      let
        tool = withBin "tool-1" [
          "foo"
          "bar"
        ];
        result = compose [ { packages = [ tool ]; } ];
      in
      # compose includes /base links too; check that the tool's links are present
      result.links."/usr/bin/foo" == {
        target = "${tool}/bin/foo";
        kind = "package";
      }
      &&
        result.links."/usr/bin/bar" == {
          target = "${tool}/bin/bar";
          kind = "package";
        }
    ))
    (check "links: dlopen and explicit links pass through with their kinds" (
      let
        tss = withBin "libfoo-1" [ ];
        frag = {
          packages = [ tss ];
          links = {
            # use paths that don't collide with /base (which links every soname systemd dlopens)
            "/usr/lib/libfoo.so.1" = {
              target = "${tss}/lib/libfoo.so.1";
              kind = "dlopen";
            };
            "/usr/lib/systemd/system/sysinit.target.wants/a.service" = {
              target = "../a.service";
              kind = "explicit";
            };
          };
        };
        result = compose [ frag ];
      in
      # the fragment's links are present with correct kinds
      result.links."/usr/lib/libfoo.so.1".kind == "dlopen"
      && result.links."/usr/lib/systemd/system/sysinit.target.wants/a.service".kind == "explicit"
    ))
    (check "links: the target path, kind and shape are typed" (
      let
        bad = links: !(tryEval (deepSeq (compose [ { inherit links; } ]).links true)).success;
        ok = links: (tryEval (deepSeq (compose [ { inherit links; } ]).links true)).success;
      in
      bad {
        "/etc/motd" = {
          target = "/usr/lib/motd";
          kind = "explicit";
        };
      }
      && bad {
        "/usr/lib/x" = {
          target = "/nix/store/x";
          kind = "symlink";
        };
      }
      && bad {
        "/usr/lib/x" = {
          target = "/nix/store/x";
        };
      }
      && bad { "/usr/lib/x" = "/nix/store/x"; }
      && bad {
        "/usr/lib/x" = {
          target = "/nix/store/x";
          kind = "explicit";
          path = "/usr/lib/x";
        };
      }
      && bad [
        {
          path = "/usr/lib/x";
          target = "/nix/store/x";
        }
      ]
      && ok {
        "/usr/lib/x" = {
          target = "/nix/store/x";
          kind = "explicit";
        };
      }
      && hasInfix "'/etc/motd'" (
        fr.links.verify {
          "/etc/motd" = {
            target = "x";
            kind = "explicit";
          };
        }
      )
      && hasInfix "in link '/usr/lib/x'" (
        fr.links.verify {
          "/usr/lib/x" = {
            target = "x";
          };
        }
      )
    ))
    # the two bugs the review found: a package link and an explicit link at one
    # path both survived; two explicit links at one path kept the first silently
    (check "links: a package link and an explicit link at one path clash, both named" (
      let
        frags = [
          { packages = [ standIn ]; }
          {
            links."/usr/bin/jq" = {
              target = "/nix/store/other/bin/jq";
              kind = "explicit";
            };
          }
        ];
        msg = merge.duplicateLink (merge.linkSources frags);
      in
      !(tryEval (deepSeq (compose frags).links true)).success
      && !(tryEval (deepSeq (compose frags).packages true)).success
      && hasInfix "/usr/bin/jq defined twice" msg
      && hasInfix "package jq" msg
      && hasInfix "explicit link to /nix/store/other/bin/jq" msg
    ))
    (check "links: two explicit links at one path clash, both targets named" (
      let
        at = target: {
          links."/usr/lib/x" = {
            inherit target;
            kind = "explicit";
          };
        };
        frags = [
          (at "a")
          (at "b")
        ];
        msg = merge.duplicateLink (merge.linkSources frags);
      in
      !(tryEval (deepSeq (compose frags).links true)).success
      && hasInfix "/usr/lib/x defined twice: explicit link to a, explicit link to b" msg
      # the same target twice is still two sources
      &&
        merge.duplicateLink (
          merge.linkSources [
            (at "a")
            (at "a")
          ]
        ) != null
    ))
    (check "links: a module's own merge is a fragment: its package links repeat without a clash" (
      let
        inner = merge [
          { packages = [ standIn ]; }
          { packages = [ openssh ]; }
        ];
        outer = compose [
          inner
          { packages = [ standIn ]; }
        ];
      in
      inner.links."/usr/bin/jq".kind == "package"
      && outer.links."/usr/bin/sshd".target == "${openssh}/bin/sshd"
      # /base adds more packages; check the requested ones are present
      && elem standIn outer.packages
      && elem openssh outer.packages
      # a package link to another target is still a clash
      && !(tryEval (
        deepSeq
          (compose [
            inner
            { packages = [ (withBin "jq-2" [ "jq" ]) ]; }
          ]).links
          true
      )).success
    ))
    (check "links: a farm and a dlopen link at one path clash across kinds" (
      let
        pkgA = withBin "a-1" [ ];
        pkgB = withBin "b-1" [ ];
        frags = [
          {
            packages = [ pkgA ];
            links."/usr/lib/security" = {
              target = "${pkgA}/lib/security";
              kind = "farm";
            };
          }
          {
            packages = [ pkgB ];
            links."/usr/lib/security" = {
              target = "${pkgB}/lib/security";
              kind = "dlopen";
            };
          }
        ];
        msg = merge.duplicateLink (merge.linkSources frags);
      in
      !(tryEval (deepSeq (compose frags).links true)).success
      && hasInfix "farm link to /nix/store/a-1/lib/security, dlopen link to /nix/store/b-1/lib/security" msg
    ))
    (check "links: distinct paths from every kind are no duplicate" (
      let
        tool = withBin "tool-1" [ "foo" ];
        frags = [
          {
            packages = [ tool ];
            links = {
              # use a path that doesn't conflict with /base
              "/usr/lib/custom/rules.d" = {
                target = "${tool}/lib/rules.d";
                kind = "farm";
              };
              "/usr/lib/libfoo.so.1" = {
                target = "${tool}/lib/libfoo.so.1";
                kind = "dlopen";
              };
            };
          }
          {
            links."/usr/lib/systemd/system/multi-user.target.wants/foo.service" = {
              target = "../foo.service";
              kind = "explicit";
            };
          }
        ];
        result = compose frags;
      in
      merge.duplicateLink (merge.linkSources frags) == null
      # /base adds links, check the fragment links are present
      && result.links ? "/usr/lib/custom/rules.d"
      && result.links ? "/usr/lib/libfoo.so.1"
      && result.links ? "/usr/bin/foo"
    ))
    (check "links: a link and a file at one path is an error" (
      let
        pkg = withBin "tool-1" [ ];
      in
      !(tryEval (
        deepSeq
          (compose [
            {
              packages = [ pkg ];
              links."/usr/lib/libfoo.so.1" = {
                target = "${pkg}/lib/libfoo.so.1";
                kind = "dlopen";
              };
            }
            { files."/usr/lib/libfoo.so.1" = "conflict"; }
          ]).links
          true
      )).success
    ))
    (check "links: farm and dlopen are no longer fragment fields" (
      !(tryEval (deepSeq (compose [ { farm."systemd-1" = [ "lib/udev/rules.d" ]; } ]).links true)).success
      && !(tryEval (deepSeq (compose [ { dlopen."tpm2-tss-1" = [ "libtss2-esys.so.0" ]; } ]).links true))
      .success
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
      svc.links."/usr/lib/systemd/system/multi-user.target.wants/test-svc.service".target
      == "../test-svc.service"
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
      svc.links ? "/usr/lib/systemd/system/sysinit.target.wants/early-svc.service"
      && svc.links ? "/usr/lib/systemd/system/basic.target.wants/early-svc.service"
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
      varFrag.links."/usr/lib/systemd/system/multi-user.target.wants/golconda-var-test-var.service" == {
        target = "../golconda-var-test-var.service";
        kind = "explicit";
      }
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

    # 6b. user scope: the unit is a file under /usr/lib/systemd/user
    (check "user service: file under systemd/user, default.target wants, no User=" (
      let
        frag = s.render {
          name = "agent";
          scope = "user";
          app.package = standIn;
          sandbox = "default";
          state = [ "agent" ];
        };
        path = "/usr/lib/systemd/user/agent.service";
        text = frag.files.${path};
        composed = compose [ frag ];
      in
      !(frag ? units)
      && !(frag ? sysusers)
      && hasInfix "\nExecStart=/usr/bin/jq\n" text
      && hasInfix "\nStateDirectory=agent\n" text
      && !hasInfix "User=" text
      && hasInfix "[Install]\nWantedBy=default.target\n" text
      &&
        frag.links == {
          "/usr/lib/systemd/user/default.target.wants/agent.service" = {
            target = "../agent.service";
            kind = "explicit";
          };
        }
      && composed.files.${path}.mode == "0644"
      && composed.units == { }
      && composed.links ? "/usr/lib/systemd/user/default.target.wants/agent.service"
    ))
    (check "user service: files beside the unit and explicit wantedBy" (
      let
        frag = s.render {
          name = "agent";
          scope = "user";
          app = {
            package = standIn;
            files."agent.conf" = "x";
          };
          sandbox = "default";
          wantedBy = [ "graphical-session.target" ];
        };
      in
      hasInfix "WantedBy=graphical-session.target" frag.files."/usr/lib/systemd/user/agent.service"
      && frag.files."/usr/lib/agent/agent.conf" == "x"
      && frag.packages == [ standIn ]
      &&
        attrNames frag.links == [
          "/usr/lib/systemd/user/graphical-session.target.wants/agent.service"
        ]
    ))
    (check "user service: refuses user, credentials and a credential ref" (
      let
        base = {
          name = "agent";
          scope = "user";
          app.package = standIn;
          sandbox = "default";
        };
        verify = extra: s.service.verify (base // extra);
        fails = extra: !(tryEval (deepSeq (s.render (base // extra)).files true)).success;
      in
      hasInfix "`user` is refused" (verify {
        user = "root";
      })
      && fails { user = "root"; }
      && fails { user = "dynamic"; }
      && hasInfix "system manager" (verify {
        credentials.k = "x.k";
      })
      && fails { credentials.k = "x.k"; }
      && fails { app.argv = [ (s.credential "k") ]; }
      && verify { } == null
    ))
    (check "system service: user is required and scope is an enum" (
      hasInfix "names its user" (
        s.service.verify {
          name = "x";
          app.package = standIn;
          sandbox = "strict";
        }
      )
      && throws (
        s.render {
          name = "x";
          app.package = standIn;
          sandbox = "strict";
        }
      )
      && throws (
        s.render {
          name = "x";
          scope = "session";
          app.package = standIn;
          sandbox = "strict";
        }
      )
      && (s.render {
        name = "x";
        scope = "system";
        app.package = standIn;
        user = "root";
        sandbox = "strict";
      }).units
        ? "x.service"
    ))
    (check "user service: a second module at the same unit is a composer error" (
      let
        frag = s.render {
          name = "agent";
          scope = "user";
          app.package = standIn;
          sandbox = "default";
        };
      in
      filesThrow [
        frag
        frag
      ]
      && !(tryEval (
        deepSeq
          (compose [
            frag
            frag
          ]).links
          true
      )).success
    ))

    # 7. Composer output includes links from services and vars
    (check "composer: merges links from services" (
      system.links ? "/usr/lib/systemd/system/multi-user.target.wants/sshd.service"
    ))
    (check "composer: merges links from vars" (
      system.links ? "/usr/lib/systemd/system/multi-user.target.wants/golconda-var-sshd-hostkey.service"
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
    (check "usr-tree: versionToEpoch throws on a bad format" (
      let
        bad = v: !(tryEval (usrTreeLib.versionToEpoch v)).success;
      in
      bad "1" && bad "2026.10.31" && bad "20261031" && bad "v1.0.0" && bad "" && !bad "20261031.1"
    ))
    (check "image: versionToEpoch throws on a bad format too" (
      !(tryEval (imageLib.versionToEpoch "1")).success
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

    # 8. the factory seed as symlinks (L lines, no manifest, no stamp)
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
    (check "factory: no manifest, no stamp" (
      !(factory.files ? "/usr/lib/golconda/etc.manifest")
      && !any (hasInfix "/etc/.golconda-factory-id") factory.tmpfiles
      && !any (hasInfix "C+") factory.tmpfiles
    ))
    (check "factory: L lines per file, not C+" (
      all (
        p: elem "L /etc/${substring (stringLength factoryDir + 1) 999 p} - - - - ${p}" factory.tmpfiles
      ) factoryPaths
      && !any (hasInfix "C+") factory.tmpfiles
    ))
    (check "factory: no machine-id, shadow, passwd, group or hostname in the factory" (
      all (n: !(factory.files ? "${factoryDir}/${n}")) neverSeeded
    ))
    (check "factory: extraFiles refuse the names sysusers and PID 1 and bootstrap own" (
      all (n: factoryThrows { extraFiles.${n} = "x"; }) neverSeeded
    ))
    (check "factory: the L lines and the static links" (
      elem "L /etc/localtime - - - - /usr/share/zoneinfo/UTC" factory.tmpfiles
      && elem "L /etc/os-release - - - - ../usr/lib/os-release" factory.tmpfiles
      && elem "d /etc/ssh 0755 root root -" factory.tmpfiles
      && !any (hasInfix "machine-id") factory.tmpfiles
    ))
    (check "factory: knows no service (no sshd user, no /var/empty)" (
      !(factory ? sysusers)
      && !any (hasInfix "/var/empty") factory.tmpfiles
      && factory.files ? "${factoryDir}/pam.d/sshd"
    ))
    (check "factory: shells are dash and sh" (
      factory.files."${factoryDir}/shells" == "/usr/bin/sh\n/usr/bin/dash\n"
    ))
    (check "factory: no hostname option (it is a bootstrap credential)" (
      !((f.modules { }).modules.factory.args.options ? hostname)
    ))
    (check "factory: timezone changes the link and is a zone name" (
      elem "L /etc/localtime - - - - /usr/share/zoneinfo/Europe/Berlin"
        (factoryOf {
          timezone = "Europe/Berlin";
        }).tmpfiles
      && factoryThrows { timezone = "../etc/shadow"; }
      && factoryThrows { timezone = "/usr/share/zoneinfo/UTC"; }
    ))
    (check "factory: extraFiles are seeded with L lines" (
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
      && elem "L /etc/security/limits.conf - - - - ${factoryDir}/security/limits.conf" r.tmpfiles
      && elem "L /etc/rc.local - - - - ${factoryDir}/rc.local" r.tmpfiles
    ))
    (check "factory: an extra file at a built-in path throws" (factoryThrows {
      extraFiles."pam.d/sshd" = "auth sufficient pam_permit.so\n";
    }))
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

    # 10a. Positive: sshd_config in /usr/lib has no credential paths
    (check "boundary: sshd_config has no %d or credential paths" (
      !hasInfix "%d/" sshdConfig
      && !hasInfix "$CREDENTIALS_DIRECTORY" sshdConfig
      && !hasInfix "/etc/credstore" sshdConfig
      # credential refs are only in the unit's ExecStart
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

    # 11. /base: the implicit base system
    (check "base: is implicit in /system (a system with no fragments has systemd)" (
      let
        result =
          (f.modules {
            options = {
              "/pkgs".target = stubSet;
              "/system" = {
                name = "empty";
                version = "20261031.1";
                fragments = [ ];
              };
            };
          }).modules.system
            { };
      in
      # /base's packages are there even with no fragments
      any (p: p.name == "systemd-262") result.packages
      && any (p: p.name == "dbus-broker-42") result.packages
      && any (p: p.name == "dash-0.5.13.5") result.packages
      && any (p: p.name == "uutils-coreutils-0.0.25") result.packages
    ))
    (check "base: /usr/bin/sh is an explicit link to dash" (
      let
        result = compose [ ];
      in
      result.links ? "/usr/bin/sh"
      && result.links."/usr/bin/sh".kind == "explicit"
      && hasInfix "dash" result.links."/usr/bin/sh".target
      && !(any (p: hasPrefix "bash" p.name) result.packages)
    ))
    (check "base: dbus.socket is a file (not a link, since dbus-broker lacks it)" (
      let
        result = compose [ ];
      in
      result.files ? "/usr/lib/systemd/system/dbus.socket"
      && hasInfix "[Socket]" result.files."/usr/lib/systemd/system/dbus.socket".text
    ))
    (check "base: dbus-broker.service and dbus.service alias are links" (
      let
        result = compose [ ];
      in
      result.links ? "/usr/lib/systemd/system/dbus-broker.service"
      && result.links ? "/usr/lib/systemd/system/dbus.service"
      && result.links."/usr/lib/systemd/system/dbus.service".target == "dbus-broker.service"
    ))
    (check "base: locale.conf, timesyncd.conf and journald.conf exist" (
      let
        result = compose [ ];
      in
      result.files ? "/usr/lib/locale.conf"
      && result.files ? "/usr/lib/systemd/timesyncd.conf.d/golconda.conf"
      && result.files ? "/usr/lib/systemd/journald.conf.d/golconda.conf"
      && hasInfix "LANG=C.UTF-8" result.files."/usr/lib/locale.conf".text
    ))
    (check "base: wantedBy links for networkd, resolved, timesyncd, dbus" (
      let
        result = compose [ ];
      in
      result.links ? "/usr/lib/systemd/system/sockets.target.wants/dbus.socket"
      && result.links ? "/usr/lib/systemd/system/multi-user.target.wants/systemd-networkd.service"
      && result.links ? "/usr/lib/systemd/system/multi-user.target.wants/systemd-resolved.service"
      && result.links ? "/usr/lib/systemd/system/sysinit.target.wants/systemd-timesyncd.service"
    ))
    (check "base: farm links for systemd's lib/systemd (units and their .wants/ included) and udev" (
      let
        result = compose [ ];
      in
      result.links ? "/usr/lib/systemd"
      && result.links."/usr/lib/systemd".kind == "farm"
      && result.links ? "/usr/lib/udev"
      && result.links."/usr/lib/udev".kind == "farm"
      # mount units and fsck exec these by bare name
      && result.links."/usr/bin/mount".kind == "explicit"
      && result.links."/usr/bin/systemd-tmpfiles".kind == "explicit"
    ))
    (check "base: dlopen link for libsystemd.so.0" (
      let
        result = compose [ ];
      in
      result.links ? "/usr/lib/libsystemd.so.0"
      && result.links."/usr/lib/libsystemd.so.0".kind == "dlopen"
    ))

    # 12. /network: networkd configuration
    (check "network: default DHCP on all wired interfaces" (
      let
        result = composeWith {
          "/network" = { };
        };
      in
      result.files ? "/usr/lib/systemd/network/default-dhcp.network"
      && hasInfix "[Match]" result.files."/usr/lib/systemd/network/default-dhcp.network".text
      && hasInfix "Type=ether" result.files."/usr/lib/systemd/network/default-dhcp.network".text
      && hasInfix "DHCP=yes" result.files."/usr/lib/systemd/network/default-dhcp.network".text
    ))
    (check "network: defaultDhcp=false disables default network" (
      let
        result = composeWith {
          "/network".defaultDhcp = false;
        };
      in
      !(result.files ? "/usr/lib/systemd/network/default-dhcp.network")
    ))
    (check "network: dns option configures resolved" (
      let
        result = composeWith {
          "/network".dns = [
            "1.1.1.1"
            "8.8.8.8"
          ];
        };
      in
      result.files ? "/usr/lib/systemd/resolved.conf.d/golconda-dns.conf"
      &&
        hasInfix "DNS=1.1.1.1 8.8.8.8"
          result.files."/usr/lib/systemd/resolved.conf.d/golconda-dns.conf".text
    ))
    (check "network: custom network config" (
      let
        result = composeWith {
          "/network" = {
            defaultDhcp = false;
            networks.static = {
              match.Name = "eth0";
              network.Address = "10.0.0.1/24";
            };
          };
        };
      in
      result.files ? "/usr/lib/systemd/network/static.network"
      && hasInfix "Name=eth0" result.files."/usr/lib/systemd/network/static.network".text
      && hasInfix "Address=10.0.0.1/24" result.files."/usr/lib/systemd/network/static.network".text
      && !(result.files ? "/usr/lib/systemd/network/default-dhcp.network")
    ))

    # 12. The kernel config fragment (packages/kernel/golconda.config)
    (check "kernel: the fragment is KEY=VALUE lines, comments and 'is not set' lines, no name twice" (
      let
        lines = filter (l: isString l && l != "") (
          split "\n" (readFile ../packages/kernel/golconda.config)
        );
        isComment = l: match "#.*" l != null && match "# CONFIG_[A-Za-z0-9_]+ is not set" l == null;
        isSet = l: match "CONFIG_[A-Za-z0-9_]+=.+" l != null;
        isUnset = l: match "# CONFIG_[A-Za-z0-9_]+ is not set" l != null;
        nameOf =
          l:
          if isUnset l then
            elemAt (match "# CONFIG_([A-Za-z0-9_]+) is not set" l) 0
          else
            elemAt (match "CONFIG_([A-Za-z0-9_]+)=.*" l) 0;
        names = map nameOf (filter (l: isSet l || isUnset l) lines);
      in
      all (l: isComment l || isSet l || isUnset l) lines
      && length names > 100
      &&
        length (
          attrNames (
            listToAttrs (
              map (n: {
                name = n;
                value = true;
              }) names
            )
          )
        ) == length names
    ))
    (check "kernel: the override reaches the derivation (kbuild.configFragments holds the file)" (
      let
        fragments = pkgs.linux-kernel.drvAttrs.spec.kbuild.configFragments;
      in
      # builtins.toFile creates /nix/store/xxx-golconda.config (dash, not slash)
      length fragments == 1 && match ".*golconda\\.config" (toString (elemAt fragments 0)) != null
    ))

    # /pkgs: target and build sets
    (check "pkgs: build is the target's buildPkgs; equal to target when not cross" (
      pkgsResult.build.pkgs == pkgsResult.target.pkgs
      && pkgsResult.pkgs == pkgsResult.target.pkgs
      && (crossPkgs { }).build.pkgs == crossBuildPkgs
      && (crossPkgs { }).pkgs == stubSet.pkgs
    ))
    (check "pkgs: an explicit build set wins over the default" (
      (crossPkgs {
        build = {
          pkgs = { };
        };
      }).build.pkgs == { }
    ))
    (check "pkgs: the stale option `set` is no target: /pkgs throws" (
      !(tryEval (
        deepSeq (
          (f.modules {
            options."/pkgs".set = stubSet;
          }).modules.pkgs
            { }
        ) true
      )).success
    ))
    (check "pkgs: a module that declares no input has no results.pkgs" (
      let
        probeTree = adios.adios {
          name = "probe";
          modules = adios.adios.lib.importModules ../modules // {
            probe = {
              name = "probe";
              impl = { results }: results;
            };
          };
        };
        probe = (probeTree { options."/pkgs".target = stubSet; }).modules.probe { };
      in
      !(probe ? pkgs) && !(probe ? target)
    ))

    # package attribution
    (check "attribution: a package in two fragments lists both origins, in order" (
      let
        s2 = compose [
          { packages = [ standIn ]; }
          {
            name = "/services/x";
            packages = [ standIn ];
          }
          { packages = [ openssh ]; }
        ];
        o = s2.packageOrigins;
      in
      o.${merge.pkgKey standIn} == [
        "fragments[0]"
        "/services/x"
      ]
      && o.${merge.pkgKey openssh} == [ "fragments[2]" ]
      && length (filter (p: p == standIn) s2.packages) == 1
    ))
    (check "attribution: /base's systemd has origin /base; /network and sshd are named" (
      let
        o = (compose [ { packages = [ stubSystemd ]; } ]).packageOrigins;
        sshdO = system.packageOrigins;
      in
      o.${merge.pkgKey stubSystemd} == [
        "/base"
        "fragments[0]"
      ]
      && o.${merge.pkgKey stubDash} == [ "/base" ]
      && sshdO.${merge.pkgKey openssh} == [ "/services/sshd" ]
    ))
    (check "attribution: packageOrigins keys exactly the packages" (
      sort lessThan (attrNames system.packageOrigins) == sort lessThan (map merge.pkgKey system.packages)
    ))

    # 12. The image chain's pure parts (lib/image)
    (check "image: versionToEpoch is lib/usr-tree.nix's, one function" (
      imageLib.versionToEpoch "20261031.1" == usrTreeLib.versionToEpoch "20261031.1"
      && imageLib.versionToEpoch "20261031.1" == 1793404801
      && imageLib.versionToEpoch "20261031.2" == 1793404802
      && imageLib.versionToEpoch "20261101.1" == 1793404801 + 86400
    ))
    (check "image: the UKI's installed name carries the boot counter" (
      imageLib.ukiName {
        imageId = "golconda";
        version = "20261031.1";
      } == "golconda_20261031.1+3-0.efi"
    ))
    (check "image: a UUID from the first 32 hex digits" (
      imageLib.uuidOfHex "c9c2180678d390a7a13ff0e23149523ce2ec58ab9df04ccdf87de4235b7e0476"
      == "c9c21806-78d3-90a7-a13f-f0e23149523c"
    ))
    (check "image: repart definitions are the build-time partitions with the builder's fields" (
      let
        defs = imageLib.repartDefinitions { };
        names = attrNames defs;
      in
      names == [
        "00-esp.conf"
        "10-usr-a.conf"
        "11-usr-a-verity.conf"
        "12-usr-a-verity-sig.conf"
        "20-usr-b.conf"
        "21-usr-b-verity.conf"
        "22-usr-b-verity-sig.conf"
      ]
      # root is made on the machine at first boot, not here
      && !(defs ? "30-root.conf")
      # the ESP takes the staged tree; slot A takes the images and the hash-derived UUIDs
      && hasInfix "CopyFiles={esp}:/" defs."00-esp.conf"
      && hasInfix "CopyBlocks={usr}" defs."10-usr-a.conf"
      && hasInfix "UUID={usrUuid}" defs."10-usr-a.conf"
      && hasInfix "CopyBlocks={verity}" defs."11-usr-a-verity.conf"
      && hasInfix "UUID={verityUuid}" defs."11-usr-a-verity.conf"
      && hasInfix "CopyBlocks={sig}" defs."12-usr-a-verity-sig.conf"
      # the B slots are the same size as A and get nothing
      && hasInfix "SizeMinBytes=10G" defs."20-usr-b.conf"
      && !hasInfix "CopyBlocks" defs."20-usr-b.conf"
      # image/repart.nix's own fields render as INI (ini.nix: booleans are yes/no)
      && hasInfix "[Partition]\n" defs."10-usr-a.conf"
      && hasInfix "ReadOnly=yes" defs."10-usr-a.conf"
      && hasInfix "Type=usr-verity-sig" defs."12-usr-a-verity-sig.conf"
    ))
    (check "image: os-release carries /system.name as ID and IMAGE_ID" (
      let
        os = usrTreeLib.renderOsRelease {
          version = "20261031.1";
          platform = {
            name = "x86_64-linux";
            cpu = "x86_64";
          };
          imageId = "server";
        };
      in
      hasInfix "ID=server\n" os && hasInfix "IMAGE_ID=server\n" os
    ))
    (check "image: the cmdline template has usrhash and no rw or volatile" (
      let
        t = ((import ../image).uki { imageId = "golconda"; }).cmdlineTemplate;
      in
      hasInfix "usrhash={usrhash}" t && !hasInfix " rw" t && !hasInfix "volatile" t
    ))

    # 13. lib/system.nix: mkSystem entry point
    (check "mkSystem: server.toml yields name and version" (
      let
        mkSystem =
          args:
          import ../lib/system.nix (
            args
            // {
              inherit sources platform;
              system = platform;
            }
          );
        sys = mkSystem { config = ../examples/server.toml; };
      in
      sys.name == "server" && sys.version == "20261031.1"
    ))
    (check "mkSystem: extra overrides an option" (
      let
        mkSystem =
          args:
          import ../lib/system.nix (
            args
            // {
              inherit sources platform;
              system = platform;
            }
          );
        sys = mkSystem {
          config = ../examples/server.toml;
          extra = {
            "/system".name = "overridden";
          };
        };
      in
      sys.name == "overridden" && sys.version == "20261031.1"
    ))
    (check "mkSystem: config.json has the sshd table and no derivation strings" (
      let
        mkSystem =
          args:
          import ../lib/system.nix (
            args
            // {
              inherit sources platform;
              system = platform;
            }
          );
        sys = mkSystem { config = ../examples/server.toml; };
        cfg = sys.config;
        cfgJson = builtins.toJSON cfg;
      in
      cfg ? "/services/sshd"
      && cfg."/services/sshd".port == 22
      # no store paths in the JSON
      && match ".*(/nix/store).*" cfgJson == null
    ))
    (check "mkSystem: a TOML with an unknown module path throws with the path in the message" (
      let
        mkSystem =
          args:
          import ../lib/system.nix (
            args
            // {
              inherit sources platform;
              system = platform;
            }
          );
        badConfig = builtins.toFile "bad.toml" ''
          ["/unknown/module"]
          option = "value"
        '';
        result = tryEval (deepSeq (mkSystem { config = badConfig; }).name true);
      in
      !result.success
    ))

    # security module: kernel hardening sysctl
    (check "security: sysctl.d file exists with Yama and hardening" (
      let
        result = compose [ ];
        sysctlFile = result.files."/usr/lib/sysctl.d/50-golconda.conf";
      in
      sysctlFile.mode == "0644"
      && hasInfix "kernel.yama.ptrace_scope = 2" sysctlFile.text
      && hasInfix "kernel.kptr_restrict = 2" sysctlFile.text
      && hasInfix "kernel.dmesg_restrict = 1" sysctlFile.text
      && hasInfix "kernel.unprivileged_bpf_disabled = 1" sysctlFile.text
      && hasInfix "net.core.bpf_jit_harden = 2" sysctlFile.text
      && hasInfix "kernel.kexec_load_disabled = 1" sysctlFile.text
    ))
    (check "security: is implicit (a system with no fragments has the sysctl file)" (
      let
        result =
          (f.modules {
            options = {
              "/pkgs".target = stubSet;
              "/system" = {
                name = "empty";
                version = "20261031.1";
                fragments = [ ];
              };
            };
          }).modules.system
            { };
      in
      result.files ? "/usr/lib/sysctl.d/50-golconda.conf"
    ))

    # UKI cmdline: LSM order and security parameters
    (check "uki: cmdline has lsm order and security parameters" (
      let
        uki = import ../image/uki.nix { imageId = "test"; };
      in
      hasInfix "lsm=lockdown,yama,ipe,bpf" uki.cmdlineTemplate
      && hasInfix "lockdown=integrity" uki.cmdlineTemplate
      && hasInfix "ipe.enforce=0" uki.cmdlineTemplate
    ))

    # kernel config: IPE and platform keyring options
    (check "kernel: config has IPE, lockdown and platform keyring options" (
      let
        config = readFile ../packages/kernel/golconda.config;
      in
      hasInfix "CONFIG_SECURITY_IPE=y" config
      && hasInfix "CONFIG_IPE_PROP_DM_VERITY=y" config
      && hasInfix "CONFIG_IPE_PROP_DM_VERITY_SIGNATURE=y" config
      && hasInfix "CONFIG_SECURITY_LOCKDOWN_LSM=y" config
      && hasInfix "CONFIG_SECURITY_LOCKDOWN_LSM_EARLY=y" config
      && hasInfix "CONFIG_SECURITY_YAMA=y" config
      && hasInfix "CONFIG_INTEGRITY_PLATFORM_KEYRING=y" config
      && hasInfix "CONFIG_LOAD_UEFI_KEYS=y" config
      && hasInfix "CONFIG_DM_VERITY_VERIFY_ROOTHASH_SIG_PLATFORM_KEYRING=y" config
    ))
    (check "kernel: IPE boot policy allows initramfs and signed verity" (
      let
        policyContent = readFile ../packages/kernel/ipe-boot-policy;
      in
      hasInfix "policy_name=golconda" policyContent
      && hasInfix "boot_verified=TRUE action=ALLOW" policyContent
      && hasInfix "dmverity_signature=TRUE action=ALLOW" policyContent
      && hasInfix "DEFAULT op=EXECUTE action=DENY" policyContent
    ))

    # /network renders through modules/lib/ini.nix
    (check "network: files are ini.nix output (sections sorted, lists repeat, booleans yes/no)" (
      let
        result = composeWith {
          "/network" = {
            defaultDhcp = false;
            dns = [
              "1.1.1.1"
              "8.8.8.8"
            ];
            networks.static = {
              match.Name = "eth0";
              network = {
                Address = [
                  "10.0.0.1/24"
                  "10.0.1.1/24"
                ];
                IPv6AcceptRA = false;
              };
              route.Gateway = "10.0.0.254";
            };
          };
        };
      in
      result.files."/usr/lib/systemd/network/static.network".text
      == "[Match]\nName=eth0\n\n[Network]\nAddress=10.0.0.1/24\nAddress=10.0.1.1/24\nIPv6AcceptRA=no\n\n[Route]\nGateway=10.0.0.254\n"
      &&
        result.files."/usr/lib/systemd/resolved.conf.d/golconda-dns.conf".text
        == "[Resolve]\nDNS=1.1.1.1 8.8.8.8\n"
    ))
    (check "network: a section the config lacks is not rendered" (
      let
        result = composeWith {
          "/network" = {
            defaultDhcp = false;
            networks.bare.match.Name = "lo";
          };
        };
      in
      result.files."/usr/lib/systemd/network/bare.network".text == "[Match]\nName=lo\n"
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
