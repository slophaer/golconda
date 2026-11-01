# Checks of /base: the implicit base system and the drop-ins for units the systemd farm ships.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  compose,
  f,
  factory,
  hasInfix,
  hasPrefix,
  stubCacert,
  stubSet,
  stubTzdata,
  ...
}:
let
  inherit (builtins) any elem;
in
[
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
    # mount units and fsck exec these by bare name; systemd-tmpfiles from the bin list of the fork's systemd
    && result.links."/usr/bin/mount".kind == "explicit"
    && result.links."/usr/bin/systemd-tmpfiles".kind == "package"
  ))
  (check "base: dlopen link for libsystemd.so.0" (
    let
      result = compose [ ];
    in
    result.links ? "/usr/lib/libsystemd.so.0"
    && result.links."/usr/lib/libsystemd.so.0".kind == "dlopen"
  ))
  (check "base: the one CA bundle is cacert's, in /usr, linked from the paths OpenSSL and curl read" (
    let
      result = compose [ ];
      bundle = "/usr/share/ca-certificates/ca-bundle.crt";
    in
    any (p: p.name == "cacert-2026.1") result.packages
    &&
      result.links."${bundle}" == {
        target = "${stubCacert}/etc/ssl/certs/ca-bundle.crt";
        kind = "explicit";
      }
    # OPENSSLDIR=/etc/ssl (openssl version -d): the default cert file
    && elem "L /etc/ssl/cert.pem - - - - ${bundle}" result.tmpfiles
    # curl's compiled-in CURL_CA_BUNDLE
    && elem "L /etc/ssl/certs/ca-certificates.crt - - - - ${bundle}" result.tmpfiles
  ))
  (check "base: tzdata, /usr/share/zoneinfo, and /etc/localtime at UTC" (
    let
      # /factory is implicit in mkSystem (lib/system.nix), not in the composer's
      # own argument; pass it, so this is the list the image's tmpfiles.d has
      result = compose [ factory ];
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
  (check "base: the coredump socket units wait for a kernel with PIDFD_INFO_COREDUMP_SIGNAL (6.19)" (
    let
      fs = (compose [ ]).files;
      k =
        u:
        hasInfix "[Unit]\nConditionKernelVersion=>=6.19"
          fs."/usr/lib/systemd/system/${u}.d/golconda.conf".text;
    in
    k "systemd-coredumpd.service" && k "systemd-coredump-register.service"
  ))
  (check "base: sysupdate units run only with a transfer definition" (
    let
      fs = (compose [ ]).files;
      cond = u: fs."/usr/lib/systemd/system/${u}.d/golconda.conf".text;
      all3 =
        t:
        hasInfix "ConditionDirectoryNotEmpty=|/usr/lib/sysupdate.d" t
        && hasInfix "ConditionDirectoryNotEmpty=|/etc/sysupdate.d" t
        && hasInfix "ConditionDirectoryNotEmpty=|/run/sysupdate.d" t;
    in
    all3 (cond "systemd-sysupdate.service") && all3 (cond "systemd-sysupdate-reboot.service")
  ))
  (check "base: networkd and timesyncd skip the initrd (no sysusers there: 217/USER)" (
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
  ))
  (check "base: the gettys skip without agetty (no local login)" (
    let
      fs = (compose [ ]).files;
    in
    hasInfix "ConditionPathExists=/usr/bin/agetty"
      fs."/usr/lib/systemd/system/getty@.service.d/golconda.conf".text
    &&
      hasInfix "ConditionPathExists=/usr/bin/agetty"
        fs."/usr/lib/systemd/system/serial-getty@.service.d/golconda.conf".text
  ))
  (check "base: no unit is masked by a link (the systemd farm owns those paths)" (
    !(builtins.any (l: l.target == "/dev/null") (builtins.attrValues (compose [ ]).links))
  ))
]
