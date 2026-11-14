# Checks of boot health gating and the loader update service.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  compose,
  composeWith,
  hasInfix,
  hasPrefix,
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
        "golconda-health-network.service"
        "golconda-initrd-failed.service"
        "golconda-loader-update.service"
        "golconda-trial-boot-failed.service"
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
    (check "loader: systemd-boot-update.service stays off (no link enables it)" (
      # it is enabled only by systemd's preset, which 00-golconda.preset turns off
      filter (p: hasInfix "systemd-boot-update" p) (attrNames baseOnly.links) == [ ]
      && hasInfix "\ndisable *\n" baseOnly.files."/usr/lib/systemd/system-preset/00-golconda.preset".text
    ))
  ]
)
++ (
  # The trial boot policy (docs/design/boot.md, "Trial boot"): a failure before the machine can be
  # reached reboots on every boot (a kernel panic, a PID 1 crash, an initrd failure or hang); a
  # failure after it (boot-complete.target failed or late) reboots only on a trial boot, a counted
  # boot with a try left, which the generator recognises at boot.
  let
    inherit (builtins)
      attrNames
      filter
      readFile
      replaceStrings
      ;
    baseOnly = compose [ ];
    later = composeWith { "/base".trialBootDeadline = "7min"; };
    file = sys: p: sys.files.${p}.text;
    generatorPath = "/usr/lib/systemd/system-generators/golconda-trial-boot-generator";
    counting = (import ../../image).bootCounting;
    initrdFailed = baseOnly.units."golconda-initrd-failed.service";
    trialFailed = baseOnly.units."golconda-trial-boot-failed.service";
  in
  [
    (check "trial boot: a kernel panic reboots (panic= on the UKI cmdline)" (
      hasInfix " panic=10 " (import ../../image).uki.cmdlineTemplate
    ))
    (check "trial boot: PID 1 reboots when it crashes, also in the initrd" (
      hasInfix "\n[Manager]\nCrashAction=reboot\n" (
        file baseOnly "/usr/lib/systemd/system.conf.d/golconda-crash.conf"
      )
    ))
    (check "trial boot: an initrd failure reboots, in the initrd only" (
      hasInfix "\nConditionPathExists=/etc/initrd-release\n" initrdFailed
      && hasInfix "\nDefaultDependencies=no\n" initrdFailed
      && hasInfix "\nSuccessAction=reboot\n" initrdFailed
      && hasInfix "\nFailureAction=reboot\n" initrdFailed
      # the serial console shows it: the kernel log, not the journal's console (tty1)
      && hasInfix "\nStandardOutput=file:/dev/kmsg\n" initrdFailed
      &&
        baseOnly.links."/usr/lib/systemd/system/emergency.target.wants/golconda-initrd-failed.service" == {
          target = "../golconda-initrd-failed.service";
          kind = "explicit";
        }
    ))
    (check "trial boot: an initrd that hangs reboots" (
      let
        t = file baseOnly "/usr/lib/systemd/system/initrd.target.d/golconda-trial-boot.conf";
      in
      hasInfix "\nJobTimeoutSec=10min\n" t && hasInfix "\nJobTimeoutAction=reboot\n" t
    ))
    (check "trial boot: the generator is executable and knows the tries a release starts with" (
      baseOnly.files.${generatorPath}.mode == "0755"
      && hasInfix "\ntries=${toString (counting.triesLeft + counting.triesDone)}\n" (
        file baseOnly generatorPath
      )
      &&
        file baseOnly generatorPath
        == replaceStrings [ "@tries@" ] [ "3" ] (readFile ../../modules/base/golconda-trial-boot-generator)
      # /bin is a tmpfiles link, made after the generators run on the first boot
      && hasPrefix "#!/usr/bin/sh\n" (file baseOnly generatorPath)
    ))
    (check "trial boot: the drop-in the generator links sets a deadline and reboots on a failure" (
      let
        t = file baseOnly "/usr/lib/golconda/trial-boot.conf";
      in
      hasInfix "\n[Unit]\n" t
      && hasInfix "\nJobTimeoutSec=15min\n" t
      && hasInfix "\nOnFailure=golconda-trial-boot-failed.service\n" t
      && hasInfix "\nJobTimeoutSec=7min\n" (file later "/usr/lib/golconda/trial-boot.conf")
      # nothing applies it statically: only the generator links it, on a trial boot
      && !(baseOnly.files ? "/usr/lib/systemd/system/boot-complete.target.d/golconda-trial-boot.conf")
      && filter (p: hasInfix "boot-complete.target.d" p) (attrNames baseOnly.files) == [ ]
    ))
    (check "trial boot: the failure unit reboots and is started by OnFailure= alone" (
      hasInfix "\nSuccessAction=reboot\n" trialFailed
      && hasInfix "\nFailureAction=reboot\n" trialFailed
      && hasInfix "\nStandardOutput=file:/dev/kmsg\n" trialFailed
      && hasInfix "\nDefaultDependencies=no\n" trialFailed
      && !(hasInfix "WantedBy=" trialFailed)
      && filter (p: hasInfix "golconda-trial-boot-failed" p) (attrNames baseOnly.links) == [ ]
    ))
  ]
)
