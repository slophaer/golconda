# Checks of /base: the built-in base system and the drop-ins for units the systemd farm ships.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  binsFor,
  check,
  compose,
  hasInfix,
  hasPrefix,
  stubSet,
  stubSystemd,
  stubTzdata,
  ...
}:
let
  inherit (builtins) all any elem;
in
[
  # 11. /base: the implicit base system
  (check "base: is built in (a system with no table has systemd)" (
    let
      # the built-in components, as mkSystem selects them (lib/components.nix)
      result = compose [ ];
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
  (check
    "base: the bus config names the activation directory (timedated and the other on-demand services)"
    (
      let
        result = compose [ ];
        conf = result.files."/usr/share/dbus-1/system.conf".text;
      in
      hasInfix "<servicedir>/usr/share/dbus-1/system-services</servicedir>" conf
      # the directory it names is the farm link to systemd's own activation files
      && result.links."/usr/share/dbus-1/system-services".kind == "farm"
    )
  )
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
    # mount units and fsck exec these by bare name; systemd-tmpfiles from the bin list of the
    # fork's systemd, which the usr tree builder links
    && result.links."/usr/bin/mount".kind == "explicit"
    && map (b: elem "systemd-tmpfiles" b.declared) (binsFor [ ] stubSystemd) == [ true ]
  ))
  (check "base: dlopen link for libsystemd.so.0" (
    let
      result = compose [ ];
    in
    result.links ? "/usr/lib/libsystemd.so.0"
    && result.links."/usr/lib/libsystemd.so.0".kind == "dlopen"
  ))
  (check "base: tzdata, /usr/share/zoneinfo, and /etc/localtime at UTC" (
    let
      # /factory is a built-in component: this is the list the image's tmpfiles.d has
      result = compose [ ];
    in
    any (p: p.name == "tzdata-2026a") result.packages
    &&
      result.links."/usr/share/zoneinfo" == {
        target = "${stubTzdata}/share/zoneinfo";
        kind = "explicit";
      }
    # the factory's line: the zone name is its `timezone` option (UTC by default)
    && elem "L /etc/localtime - - - - /usr/share/zoneinfo/UTC" result.tmpfiles
  ))
  # base module: drop-ins for units the systemd farm ships
  (check "base: systemd-firstboot never prompts" (
    let
      f = (compose [ ]).files."/usr/lib/systemd/system/systemd-firstboot.service.d/golconda.conf".text;
    in
    hasInfix "ExecStart=\nExecStart=systemd-firstboot --mute-console=yes" f && !(hasInfix "--prompt" f)
  ))
  (check "base: ldconfig and modprobe@ skip on a missing binary" (
    let
      fs = (compose [ ]).files;
    in
    hasInfix "ConditionPathExists=/usr/bin/ldconfig"
      fs."/usr/lib/systemd/system/ldconfig.service.d/golconda.conf".text
    &&
      hasInfix "ConditionPathExists=/usr/bin/modprobe"
        fs."/usr/lib/systemd/system/modprobe@.service.d/golconda.conf".text
  ))
  (check "base: the D-Bus system policy is default-deny and takes systemd's service policies" (
    let
      c = compose [ ];
      conf = c.files."/usr/share/dbus-1/system.conf".text;
      farm = dir: {
        target = "${stubSet.pkgs.systemd}/share/dbus-1/${dir}";
        kind = "farm";
      };
    in
    # every user may connect; no one owns a name or calls a method unless a policy says so
    hasInfix "<allow user=\"*\"/>" conf
    && hasInfix "<deny own=\"*\"/>" conf
    && hasInfix "<deny send_type=\"method_call\"/>" conf
    && !hasInfix "<allow own=\"*\"/>" conf
    && !hasInfix "<allow send_destination=\"*\"/>" conf
    && hasInfix "<includedir>system.d</includedir>" conf
    && c.links."/usr/share/dbus-1/system.d" == farm "system.d"
    && c.links."/usr/share/dbus-1/system-services" == farm "system-services"
    && !(c.files ? "/usr/share/dbus-1/system.d/.gitkeep")
  ))
  (check "base: each PAM package's modules are a directory link under /usr/lib/security" (
    # a directory link, not file links: repkgs writes DT_NEEDED as $ORIGIN/../../../<dep>,
    # and $ORIGIN is the directory of the path PAM opens
    let
      l = (compose [ ]).links;
    in
    l."/usr/lib/security/linux-pam" == {
      target = "${stubSet.pkgs.linux-pam}/lib/security";
      kind = "explicit";
    }
    &&
      l."/usr/lib/security/systemd" == {
        target = "${stubSet.pkgs.systemd}/lib/security";
        kind = "explicit";
      }
    && !(l ? "/usr/lib/security/pam_unix.so")
  ))
  (check "base: systemd's NvPCR definitions are in the farm (/usr/lib/nvpcr)" (
    (compose [ ]).links."/usr/lib/nvpcr" == {
      target = "${stubSet.pkgs.systemd}/lib/nvpcr";
      kind = "farm";
    }
  ))
  (check "base: 00-golconda.preset disables every unit (the static links enable them)" (
    # PID 1 runs preset-all on the first boot; with `disable *` first, systemd's own
    # 90-systemd.preset and its default (enable) never apply (docs/design/layout.md)
    (compose [ ]).files."/usr/lib/systemd/system-preset/00-golconda.preset".text
    == "# Generated by Golconda (/base): units are enabled by static links in /usr\ndisable *\n"
  ))
  (check "base: networkd's generator and wait-online are enabled by static links" (
    let
      l = (compose [ ]).links;
    in
    # network.* credentials (docs/features/provisioning.md)
    l."/usr/lib/systemd/system/sysinit.target.wants/systemd-network-generator.service" == {
      target = "../systemd-network-generator.service";
      kind = "explicit";
    }
    # network-online.target waits for a configured network (systemd-imds-import.service)
    &&
      l."/usr/lib/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service" == {
        target = "../systemd-networkd-wait-online.service";
        kind = "explicit";
      }
  ))
  (check "base: no drop-in for a unit only systemd's preset enabled" (
    let
      fs = (compose [ ]).files;
    in
    all (u: !(fs ? "/usr/lib/systemd/system/${u}.d/golconda.conf")) [
      "systemd-coredumpd.service"
      "systemd-coredump-register.service"
      "systemd-sysupdate.service"
      "systemd-sysupdate-reboot.service"
      "systemd-boot-update.service"
      "getty@.service"
    ]
  ))
  (check "base: networkd, timesyncd and the network generator skip the initrd" (
    let
      fs = (compose [ ]).files;
      skips =
        u:
        hasInfix "[Unit]\nConditionPathExists=!/etc/initrd-release"
          fs."/usr/lib/systemd/system/${u}.d/golconda.conf".text;
    in
    skips "systemd-networkd.service"
    && skips "systemd-networkd.socket"
    && skips "systemd-timesyncd.service"
    && skips "systemd-network-generator.service"
  ))
  (check "base: the serial getty skips without agetty (no local login)" (
    # systemd-getty-generator pulls serial-getty@ttyS0.service in from the console= argument
    hasInfix "ConditionPathExists=/usr/bin/agetty"
      (compose [ ]).files."/usr/lib/systemd/system/serial-getty@.service.d/golconda.conf".text
  ))
  (check "base: no unit is masked by a link (the systemd farm owns those paths)" (
    !(builtins.any (l: l.target == "/dev/null") (builtins.attrValues (compose [ ]).links))
  ))
]
