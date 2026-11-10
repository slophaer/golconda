# Checks of the sshd module on the mkSystem fixture: unit, config file, credentials, the certificate options,
# and the exact list of units the fixture composes.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  composeWith,
  f,
  fixturePkgs,
  hasInfix,
  hasPrefix,
  merge,
  mkSystemFixture,
  sshd,
  sshdConfig,
  sshdDir,
  system,
  throws,
  types,
  unit,
  withBin,
  ...
}:
let
  inherit (builtins)
    all
    any
    attrNames
    elem
    head
    ;

  # the usr tree's /usr/bin entry for openssh (lib/usr-tree.nix packageBins): the builder
  # links its declared bin names
  opensshBins = head (
    builtins.filter (
      b: b.package == merge.pkgKey fixturePkgs.openssh
    ) mkSystemFixture.usrTree.packageBins
  );

  # 1a. sshd with certificates: a user CA, principals, a KRL and a host certificate
  # a component enters by its table (lib/components.nix)
  certSshd = composeWith {
    "/services/sshd" = {
      trustedUserCAKeys = [ "ssh-ed25519 AAAA user-ca" ];
      principals.root = [ "alice@example.com" ];
      revokedKeys = true;
      hostCertificate = true;
    };
  };
  certUnit = certSshd.units."sshd.service";
  certConfig = certSshd.files."${sshdDir}/sshd_config".text;
  sshdOptions = attrNames (import ../../modules/services/sshd/default.nix { inherit types; }).options;
  sshdThrows =
    opts:
    throws (composeWith {
      "/services/sshd" = opts;
    });
in
[
  (check "sshd: LoadCredentialEncrypted" (hasInfix "LoadCredentialEncrypted=sshd-hostkey.key\n" unit))
  (check "sshd: credential ref renders as %d" (hasInfix " -h %d/sshd-hostkey.key" unit))
  (check "sshd: ExecStart is the program from the farm with its config and credential" (
    hasInfix "\nExecStart=/usr/bin/sshd -D -e -f /usr/lib/sshd/sshd_config -h %d/sshd-hostkey.key\n" unit
    # the image builder links /usr/bin/sshd: openssh declares it in bin
    && elem "sshd" opensshBins.declared
    && opensshBins.path == fixturePkgs.openssh.outPath
    && opensshBins.origins == [ "/services/sshd" ]
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
  (check "sshd: the helpers sshd execs by compiled-in path are at /usr/lib/ssh" (
    system.links."/usr/lib/ssh" == {
      target = "${fixturePkgs.openssh}/lib/ssh";
      kind = "farm";
    }
  ))
  # the image builder fails when the program a unit runs is not in /usr/bin
  # (tests/usr-tree/builder.py): the fragment and the usr tree carry it with its origin
  (check "sshd: the usr tree checks that /usr/bin/sshd exists" (
    sshd.programs == [ "sshd" ]
    && system.programs == [ "sshd" ]
    && system.origins.programs.sshd == [ "/services/sshd" ]
    &&
      mkSystemFixture.usrTree.programs == [
        {
          name = "sshd";
          origins = [ "/services/sshd" ];
        }
      ]
  ))
  (check "sshd: the package's other tools are in the farm" (
    elem "ssh-keygen" opensshBins.declared && elem "ssh" opensshBins.declared
  ))
  (check "sshd: valid options compose (sshdThrows has teeth)" (
    !(sshdThrows { }) && !(sshdThrows { port = 2222; })
  ))
  # a TCP port to listen on: 1 to 65535 (0 would be any port, and -1 none)
  (check "sshd: port is a TCP port, in the module and in the schema" (
    let
      port = f.schema.properties."/services/sshd".properties.port;
    in
    !(sshdThrows { port = 1; })
    && !(sshdThrows { port = 65535; })
    && sshdThrows { port = 0; }
    && sshdThrows { port = -1; }
    && sshdThrows { port = 65536; }
    && sshdThrows { port = "22"; }
    && port.type == "integer"
    && port.minimum == 1
    && port.maximum == 65535
  ))
  # a package that declares `bin` without sshd: refused at evaluation; an undeclared
  # package's program is checked by the image builder (tests/usr-tree/builder.py)
  (check "sshd: the program must be one of the package's declared executables" (sshdThrows {
    package = withBin "jq-1.8.1" [ "jq" ];
  }))
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
      "\nExecStart=/usr/bin/sshd -D -e -f /usr/lib/sshd/sshd_config -h %d/sshd-hostkey.key"
      + " -o HostCertificate=%d/sshd-host-cert.cert -o RevokedKeys=%d/sshd-revoked-keys.krl\n"
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
    hasInfix "LoadCredentialEncrypted=sshd-host-cert.cert\n" certUnit
    && hasInfix " -o HostCertificate=%d/sshd-host-cert.cert" certUnit
  ))
  (check "sshd: revoked keys credential and option" (
    hasInfix "LoadCredentialEncrypted=sshd-revoked-keys.krl\n" certUnit
    && hasInfix " -o RevokedKeys=%d/sshd-revoked-keys.krl" certUnit
  ))
  (check "sshd: the admin vars are declared, with sshd as their consumer" (
    builtins.fromJSON certSshd.files."/usr/lib/golconda/vars.d/sshd-host-cert.json".text == {
      name = "sshd-host-cert";
      class = "admin";
      files = [ "cert" ];
      credentials = [ "sshd-host-cert.cert" ];
      consumers = [ "sshd.service" ];
    }
    &&
      (builtins.fromJSON certSshd.files."/usr/lib/golconda/vars.d/sshd-revoked-keys.json".text)
      .credentials == [ "sshd-revoked-keys.krl" ]
    && !(certSshd.units ? "golconda-var-sshd-host-cert.service")
  ))
  # the image accepts them before it uses them: the bootstrap pushes to a release that has the
  # options off, then a release with them on reads what was pushed (docs/design/trust.md)
  (check "sshd: the admin vars are declared with their options off, and nothing loads them" (
    system.files ? "/usr/lib/golconda/vars.d/sshd-host-cert.json"
    && system.files ? "/usr/lib/golconda/vars.d/sshd-revoked-keys.json"
    && !hasInfix "sshd-host-cert" system.units."sshd.service"
    && !hasInfix "sshd-revoked-keys" system.units."sshd.service"
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
  (check "sshd: the host key is loaded after the PCR phase it is sealed for" (
    # systemd-pcrphase-sysinit.service extends PCR 11 to ...:sysinit before
    # basic.target; sshd must not start before it, or the sealed host key has
    # no signed phase to match
    hasInfix "\nAfter=systemd-pcrphase-sysinit.service\n" unit
  ))
  # the units of the fixture, exactly: a new unit is a decision, not an accident
  (check "sshd: the fixture composes exactly these units" (
    attrNames system.units == [
      "golconda-etc-links.service"
      "golconda-health-network.service"
      "golconda-health-sshd.service"
      "golconda-loader-update.service"
      "golconda-var-sshd-hostkey.service"
      "sshd.service"
    ]
  ))
]
