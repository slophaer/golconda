# Checks of the IMDS (cloud instance metadata) support: systemd's build options, /base's
# drop-ins that keep systemd's IMDS units off without `/imds`, the `/imds` component that turns
# systemd's own stack and import on, the networkd drop-ins that keep DHCP from setting the host
# name, and the cmdline that keeps the generator from pulling the import into the initrd.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  compose,
  composeWith,
  configLib,
  fixturePkgs,
  hasInfix,
  hasSuffix,
  sources,
  ...
}:
let
  inherit (builtins)
    all
    any
    attrNames
    ;
  # the file only /imds ships: /base's drop-ins turn the IMDS units on by its path
  marker = "/usr/lib/golconda/imds";
  importUnit = "systemd-imds-import.service";
  # systemd-imds-early-network.service has no [Install], so only the generator pulls it, on a
  # cloud; systemd's preset enables systemd-imdsd.socket on every machine
  wantsLink = "/usr/lib/systemd/system/systemd-imds-early-network.service.wants/${importUnit}";
  # systemd's IMDS units: the generator pulls them in on a cloud, the preset enables the socket
  stackUnits = [
    "systemd-imdsd.socket"
    "systemd-imdsd@.service"
    "systemd-imds-early-network.service"
    "systemd-imds-metrics.socket"
    "systemd-imds-metrics@.service"
    importUnit
  ];
  dropIn = u: "/usr/lib/systemd/system/${u}.d/golconda.conf";
  importDropIn = "/usr/lib/systemd/system/${importUnit}.d/golconda-imds.conf";
  # systemd's meson options as packages/systemd/package.nix writes them
  defs = fixturePkgs.systemd.args.meson.defs;
  # networkd's .network files: /network's, and the one systemd-imdsd writes at run time on a
  # cloud (/run/systemd/network/85-imds-early.network, DHCP with UseHostname=yes)
  netDir = "/usr/lib/systemd/network";
  noDhcpName = n: "${netDir}/${n}.network.d/golconda-imds.conf";
  dhcpNameOff =
    r: n:
    let
      t = r.files.${noDhcpName n}.text or "";
    in
    hasInfix "[DHCPv4]\nUseHostname=no\n" t && hasInfix "[DHCPv6]\nUseHostname=no\n" t;
  anyDhcpDropIn =
    r: any (p: hasSuffix "/golconda-imds.conf" p && hasInfix ".network.d/" p) (attrNames r.files);
  lan = {
    "/network".networks.lan.match.Name = "eth1";
  };
  # the udev rule that carried Hetzner's paths before packages/systemd patched 40-imds.hwdb
  hetznerRule = "/usr/lib/udev/rules.d/70-golconda-imds.rules";
  # the second run of systemd-network-generator, for the user data's network.* credentials
  netUnit = "golconda-imds-network.service";
  netWants = "/usr/lib/systemd/system/${importUnit}.wants/${netUnit}";
  withImds = composeWith { "/imds" = { }; };
  # the IMDS lock on lo: a user data .network file for the link replaces 85-imds-early.network
  lockFile = "${netDir}/10-golconda-imds-lock.network";
in
[
  (check "imds: systemd builds the IMDS stack, its network mode locked" (
    defs.imds == "enabled"
    # locked: a prohibit route to the endpoint, so only imdsd (fwmark) reaches it
    && defs."imds-network" == "locked"
    # meson refuses imds without curl
    && defs.libcurl == "enabled"
  ))
  (check "imds: the cmdline keeps the generator from pulling the import (it would, in the initrd)" (
    hasInfix " systemd.imds.import=0" (import ../../image).uki.cmdlineTemplate
  ))
  (check "imds: without /imds, /base keeps every IMDS unit off by a path only /imds ships" (
    let
      r = compose [ ];
    in
    all (u: hasInfix "ConditionPathExists=${marker}\n" (r.files.${dropIn u}.text or "")) stackUnits
    && !(r.files ? ${marker})
    && !(r.links ? ${wantsLink})
    && !(r.files ? ${importDropIn})
  ))
  (check "imds: the initrd (/base alone) has no /imds, so the IMDS units stay off there" (
    let
      initrd = (import ../../lib/image { }).initrdSystem {
        imageId = "t";
        version = "20261031.1";
        pkgs = fixturePkgs;
        inherit sources;
        platform.name = "x86_64-linux";
        buildSystem = "x86_64-linux";
      };
    in
    initrd.composed.files ? ${dropIn importUnit} && !(initrd.composed.files ? ${marker})
  ))
  (check "imds: an empty /imds table turns systemd's stack and its own import on" (
    let
      r = composeWith { "/imds" = { }; };
    in
    r.files ? ${marker}
    # the generator pulls the early network unit on a cloud only; it pulls the import
    && r.links.${wantsLink}.target == "../${importUnit}"
    && r.links.${wantsLink}.kind == "explicit"
    # no script of Golconda's: the unit is systemd's
    && !(r.units ? "golconda-imds-import.service")
    && all (p: !(hasInfix "golconda-imds-import" p)) (attrNames r.files)
  ))
  (check "imds: the import ends before tmpfiles reads ssh.authorized_keys.root and tmpfiles.*" (
    hasInfix "[Unit]\nBefore=systemd-tmpfiles-setup.service\n"
      (composeWith { "/imds" = { }; }).files.${importDropIn}.text
  ))
  (check "imds: /imds has no options (the operator opts in with the table, systemd decides the rest)"
    (
      configLib.optionError "/imds" { } == null
      && configLib.optionError "/imds" { import = [ "hostname" ]; } != null
    )
  )
  (check "imds: without /imds, DHCP may still set the host name (no drop-in)" (
    let
      r = composeWith lan;
    in
    !(anyDhcpDropIn r) && hasInfix "UseHostname=yes" r.files."${netDir}/99-default-dhcp.network".text
  ))
  (check "imds: with /imds, no DHCP lease sets the host name" (
    let
      r = composeWith (lan // { "/imds" = { }; });
    in
    dhcpNameOff r "99-default-dhcp" && dhcpNameOff r "50-lan" && dhcpNameOff r "85-imds-early"
  ))
  (check "imds: Hetzner's paths come from systemd's own hwdb, patched, not from a rule of /imds" (
    let
      patches = map toString fixturePkgs.systemd.patches;
    in
    any (hasSuffix "hwdb-imds-hetzner.patch") patches
    # the ssh keys as Hetzner's JSON array: the well-known key ssh-key-json, and hwdb naming it
    && any (hasSuffix "imds-ssh-key-json.patch") patches
    && any (hasSuffix "hwdb-imds-hetzner-ssh-keys.patch") patches
    && !(withImds.files ? ${hetznerRule})
    && all (p: !(hasInfix "/udev/rules.d/" p)) (attrNames withImds.files)
  ))
  (check "imds: user data network.* credentials take effect in the boot that imports them" (
    let
      u = withImds.units.${netUnit} or "";
      has = x: hasInfix x u;
    in
    !((composeWith lan).units ? ${netUnit})
    && !((composeWith lan).links ? ${netWants})
    # the import pulls it in, so it runs where the import runs
    && (withImds.links.${netWants}.target or "") == "../${netUnit}"
    && (withImds.links.${netWants}.kind or "") == "explicit"
    && has "\nAfter=${importUnit}\n"
    && has "\nImportCredential=network.netdev.*\nImportCredential=network.link.*\nImportCredential=network.network.*\n"
    # systemd's own programs, no script: the generator writes /run/systemd/network, networkd
    # reloads and reconfigures the links whose file changed
    && has "\nExecStart=/usr/lib/systemd/systemd-network-generator\n"
    && has "\nExecStart=/usr/bin/networkctl reload\n"
  ))
  (check "imds: the kernel has IPv6 policy routing, which the lock's IPv6 rules and imdsd's need" (
    # without it networkd cannot set an IPv6 rule, and the file's IPv4 rules are lost with it
    hasInfix "\nCONFIG_IPV6_MULTIPLE_TABLES=y\n" (
      builtins.readFile ../../packages/kernel/golconda.config
    )
  ))
  (check "imds: the endpoint lock is on lo, where a .network file for the link does not replace it" (
    let
      t = withImds.files.${lockFile}.text or "";
      has = x: hasInfix x t;
    in
    !((composeWith lan).files ? ${lockFile})
    && has "[Match]\nName=lo\n"
    # imdsd's own rule, before the next one: its table has the route while 85-imds-early.network
    # is in use, and the main table then has a prohibit route to the endpoint
    && has "[RoutingPolicyRule]\nFirewallMark=0x7FFF0815\nTable=0x7FFF0815\nPriority=32100\n"
    # once the link has another file, imdsd's table is empty: marked packets take the main table
    && has "[RoutingPolicyRule]\nFirewallMark=0x7FFF0815\nTable=main\nPriority=32101\n"
    # every other packet to the endpoint is refused, whatever file the link has
    && has "[RoutingPolicyRule]\nTo=169.254.169.254/32\nType=prohibit\nPriority=32102\n"
    # no DHCP host name drop-in: lo has no DHCP
    && !(withImds.files ? "${netDir}/10-golconda-imds-lock.network.d/golconda-imds.conf")
  ))
]
