# Checks of /factory: the /etc seed under /usr/share/factory/etc as symlinks.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  f,
  factory,
  factoryDir,
  factoryOf,
  factoryThrows,
  filesThrow,
  hasInfix,
  hasPrefix,
  pamSshd,
  ...
}:
let
  inherit (builtins)
    all
    any
    attrNames
    elem
    stringLength
    substring
    ;

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
in
[
  # 8. the factory seed as symlinks (L lines, no manifest, no stamp)
  (check "factory: pam.d/sshd is account and session only" (
    hasInfix "\naccount required linux-pam/pam_unix.so\n" pamSshd
    && hasInfix "\nsession optional systemd/pam_systemd.so\n" pamSshd
    && hasInfix "\nsession required linux-pam/pam_unix.so\n" pamSshd
    && !hasInfix "\nauth " pamSshd
    && !hasInfix "\npassword " pamSshd
  ))
  (check "factory: pam.d/systemd-user is systemd's stack with <package>/<module> names" (
    let
      t = factory.files."${factoryDir}/pam.d/systemd-user";
    in
    hasInfix "\naccount required linux-pam/pam_unix.so no_pass_expiry\n" t
    && hasInfix "\nauth required linux-pam/pam_rootok.so\n" t
    && hasInfix "\nsession required linux-pam/pam_loginuid.so\n" t
    && hasInfix "\nsession optional systemd/pam_systemd.so\n" t
    && !hasInfix "pam_namespace" t
  ))
  (check "factory: pam.d/other denies everything" (
    all
      (t: hasInfix "\n${t} required linux-pam/pam_deny.so\n" factory.files."${factoryDir}/pam.d/other")
      [
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
  (check "factory: extraFiles cannot replace generated static links" (
    factoryThrows { extraFiles.localtime = "x"; } && factoryThrows { extraFiles."os-release" = "x"; }
  ))
  (check "factory: generated static links each appear once with the configured timezone" (
    let
      r = factoryOf {
        timezone = "Europe/Berlin";
        extraFiles.motd = "Welcome\n";
      };
      linesFor = path: builtins.filter (hasPrefix "L ${path} ") r.tmpfiles;
    in
    linesFor "/etc/localtime" == [ "L /etc/localtime - - - - /usr/share/zoneinfo/Europe/Berlin" ]
    && linesFor "/etc/os-release" == [ "L /etc/os-release - - - - ../usr/lib/os-release" ]
    && r.files."${factoryDir}/motd" == "Welcome\n"
  ))
  (check "factory: the L lines and the static links" (
    elem "L /etc/localtime - - - - /usr/share/zoneinfo/UTC" factory.tmpfiles
    && elem "L /etc/os-release - - - - ../usr/lib/os-release" factory.tmpfiles
    && !any (hasInfix "machine-id") factory.tmpfiles
  ))
  # sshd takes its config with -f and its host key with -h; the paths openssh compiles
  # in under /etc/ssh (moduli, sshrc, ssh_config) are optional and the image ships none,
  # so an empty /etc/ssh would answer as a missing one does
  (check "factory: makes no empty directory" (!any (hasPrefix "d ") factory.tmpfiles))
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
  (check "factory: valid options compose (factoryThrows has teeth)" (
    !(factoryThrows { })
    && !(factoryThrows {
      timezone = "Europe/Berlin";
      extraFiles."motd" = "hi\n";
    })
  ))
  # /factory is a built-in component: compose always has one
  (check "factory: a second module at a factory path is a composer error" (filesThrow [
    { files."${factoryDir}/pam.d/sshd" = "x"; }
  ]))
  (check "factory: two factories are a composer error" (filesThrow [
    (factoryOf { })
  ]))
]
