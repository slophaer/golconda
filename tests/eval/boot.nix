# Checks of boot health gating and the loader update service.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  compose,
  hasInfix,
  system,
  ...
}:
(
  # A release is blessed only when the machine is usable. systemd-bless-boot.service
  # requires boot-complete.target and is After= it, so reaching the target is the whole
  # blessing condition. Each health unit gets Required= from a `.requires` link (a link adds
  # no ordering) and orders itself Before= the target; no other link or target pulls it in.
  let
    inherit (builtins) attrNames;
    baseOnly = compose [ ];
    requires = u: "/usr/lib/systemd/system/boot-complete.target.requires/${u}";
    # every link whose path names the unit: the single `.requires` link
    linksNaming = sys: u: builtins.filter (p: hasInfix u p) (attrNames sys.links);
    gated =
      sys: u:
      sys.units ? ${u}
      && hasInfix "\nBefore=boot-complete.target\n" sys.units.${u}
      && sys.links ? ${requires u}
      &&
        sys.links.${requires u} == {
          target = "../${u}";
          kind = "explicit";
        }
      && linksNaming sys u == [ (requires u) ];
  in
  [
    (check "boot health: /base fails boot-complete.target unless the network has a routable link" (
      gated baseOnly "golconda-health-network.service"
      &&
        hasInfix
          "\nExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --operational-state=routable --timeout=60\n"
          baseOnly.units."golconda-health-network.service"
      && hasInfix "\nAfter=systemd-networkd.service\n" baseOnly.units."golconda-health-network.service"
    ))
    (check "boot health: /services/sshd fails boot-complete.target unless sshd is active" (
      gated system "golconda-health-sshd.service"
      &&
        hasInfix "\nExecStart=/usr/bin/systemctl is-active --quiet sshd.service\n"
          system.units."golconda-health-sshd.service"
      && hasInfix "\nAfter=sshd.service\n" system.units."golconda-health-sshd.service"
    ))
    (check "boot health: systemd's own bless-boot ordering is untouched" (
      # systemd ships systemd-bless-boot.service and the generator wants it from basic.target;
      # the module supplies no copy, no mask and no WantedBy= of its own
      !(system.units ? "systemd-bless-boot.service")
      && !(system.files ? "/usr/lib/systemd/system/systemd-bless-boot.service")
      && !(system.links ? "/usr/lib/systemd/system/basic.target.wants/systemd-bless-boot.service")
      && !(hasInfix "WantedBy=" system.units."golconda-health-network.service")
      && !(hasInfix "WantedBy=" system.units."golconda-health-sshd.service")
    ))
    (check "boot health: a configuration without /services/sshd still gates the network" (
      attrNames baseOnly.units == [
        "golconda-etc-links.service"
        "golconda-health-network.service"
        "golconda-loader-update.service"
      ]
      && linksNaming baseOnly "golconda-health-sshd" == [ ]
    ))
  ]
)
++ (
  # The ESP's loader follows /usr. golconda-loader-update.service is wanted by
  # systemd-bless-boot.service and Requisite= it, so it runs only on a counted boot that
  # passed the health gate; it is the one writer of the loader (systemd-boot-update.service is
  # off); its loader.conf is image/loader.nix's (docs/design/bootloader.md).
  let
    inherit (builtins) attrNames filter;
    baseOnly = compose [ ];
    u = baseOnly.units."golconda-loader-update.service";
    wants = "/usr/lib/systemd/system/systemd-bless-boot.service.wants/golconda-loader-update.service";
    script = baseOnly.files."/usr/lib/golconda/golconda-loader-update";
    dropIn = baseOnly.files."/usr/lib/systemd/system/systemd-boot-update.service.d/golconda.conf";
  in
  [
    (check "loader: the update runs after a good counted boot and never without one" (
      hasInfix "\nAfter=systemd-bless-boot.service\n" u
      && hasInfix "\nRequisite=systemd-bless-boot.service\n" u
      && hasInfix "\nExecStart=/usr/lib/golconda/golconda-loader-update\n" u
      && hasInfix "\nConditionPathExistsGlob=/usr/lib/systemd/boot/efi/systemd-boot*.efi.signed\n" u
      # pulled in by bless-boot alone: no WantedBy= and no other link names it
      && !(hasInfix "WantedBy=" u)
      &&
        baseOnly.links.${wants} == {
          target = "../golconda-loader-update.service";
          kind = "explicit";
        }
      && filter (p: hasInfix "golconda-loader-update" p) (attrNames baseOnly.links) == [ wants ]
    ))
    (check "loader: the program is executable" (script.mode == "0755"))
    (check "loader: /usr carries image/loader.nix's loader.conf" (
      baseOnly.files."/usr/lib/golconda/loader.conf".text == (import ../../image).loader.conf
    ))
    (check "loader: systemd-boot-update.service stays off" (
      hasInfix "\nConditionPathExists=!/usr/lib/golconda/golconda-loader-update\n" dropIn.text
    ))
  ]
)
