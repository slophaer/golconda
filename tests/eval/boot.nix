# Checks of boot health gating and the loader update service.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  compose,
  f,
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
        "golconda-emergency-reboot.service"
        "golconda-esp-credentials.service"
        "golconda-failed-boots-complete.service"
        "golconda-failed-boots.service"
        "golconda-health-network.service"
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
    file = sys: p: sys.files.${p}.text;
    generatorPath = "/usr/lib/systemd/system-generators/golconda-trial-boot-generator";
    counting = (import ../../image).bootCounting;
    emergency = baseOnly.units."golconda-emergency-reboot.service";
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
    (check "trial boot: PID 1 runs the hardware watchdog, 30 s, and 10 min for a reboot" (
      let
        t = file baseOnly "/usr/lib/systemd/system.conf.d/golconda-watchdog.conf";
      in
      hasInfix "\n[Manager]\n" t
      && hasInfix "\nRuntimeWatchdogSec=30s\n" t
      && hasInfix "\nRebootWatchdogSec=10min\n" t
    ))
    (check "trial boot: emergency.target reboots, in the initrd and in the host" (
      # no initrd condition: a unit of the host that fails into emergency.target reboots too
      !(hasInfix "initrd-release" emergency)
      && hasInfix "\nDefaultDependencies=no\n" emergency
      && hasInfix "\nSuccessAction=reboot\n" emergency
      && hasInfix "\nFailureAction=reboot\n" emergency
      # the serial console shows it: the kernel log, not the journal's console (tty1)
      && hasInfix "\nStandardOutput=file:/dev/kmsg\n" emergency
      &&
        baseOnly.links."/usr/lib/systemd/system/emergency.target.wants/golconda-emergency-reboot.service"
        == {
          target = "../golconda-emergency-reboot.service";
          kind = "explicit";
        }
      &&
        filter (p: hasInfix "emergency.target" p) (attrNames baseOnly.links) == [
          "/usr/lib/systemd/system/emergency.target.wants/golconda-emergency-reboot.service"
        ]
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
++ (
  # The failed-boot counter (docs/design/boot.md, "Failed boots"): the initrd counts each boot in an
  # EFI variable before anything can fail, a complete boot resets it; after the tries a release
  # starts with, boots in a row, the next starts the other slot once, after twice that nothing
  # reboots.
  let
    inherit (builtins) attrNames readFile replaceStrings;
    baseOnly = compose [ ];
    counting = (import ../../image).bootCounting;
    tries = counting.triesLeft + counting.triesDone;
    program = "/usr/lib/golconda/golconda-failed-boots";
    count = baseOnly.units."golconda-failed-boots.service";
    complete = baseOnly.units."golconda-failed-boots-complete.service";
    haltSkips = "\nConditionPathExists=!/run/golconda/failed-boots-halt\n";
  in
  [
    (check "failed boots: the initrd counts the boot early, from sysinit.target" (
      hasInfix "\nConditionPathExists=/etc/initrd-release\n" count
      && hasInfix "\nConditionFirmware=uefi\n" count
      && hasInfix "\nDefaultDependencies=no\n" count
      && hasInfix "\nBefore=sysinit.target\n" count
      && hasInfix "\nExecStart=${program} count\n" count
      # a boot that the Secure Boot check halts is not a failed boot: the halt comes first
      && hasInfix "\nAfter=golconda-secure-boot-required.service\n" count
      &&
        baseOnly.links."/usr/lib/systemd/system/sysinit.target.wants/golconda-failed-boots.service" == {
          target = "../golconda-failed-boots.service";
          kind = "explicit";
        }
    ))
    (check "failed boots: the host resets the count after multi-user.target and boot-complete.target" (
      hasInfix "\nConditionPathExists=!/etc/initrd-release\n" complete
      && hasInfix "\nAfter=multi-user.target boot-complete.target\n" complete
      && hasInfix "\nExecStart=${program} complete\n" complete
      # no Requires=: an uncounted boot has no boot-complete.target, and must not pull it in
      && !(hasInfix "Requires=" complete)
      &&
        baseOnly.links."/usr/lib/systemd/system/multi-user.target.wants/golconda-failed-boots-complete.service"
        == {
          target = "../golconda-failed-boots-complete.service";
          kind = "explicit";
        }
    ))
    (check "failed boots: the program carries the thresholds, the tries of a release and twice that" (
      baseOnly.files.${program}.mode == "0755"
      &&
        baseOnly.files.${program}.text == replaceStrings
          [ "@fallback@" "@halt@" ]
          [
            (toString tries)
            (toString (2 * tries))
          ]
          (readFile ../../modules/base/golconda-failed-boots)
      && hasInfix "\nfallback=3\nhalt=6\n" baseOnly.files.${program}.text
      # constants: the document sets neither threshold nor the trial boot deadline, so the
      # initrd, built from /base alone, has the same program as the host
      &&
        attrNames (f.modules { }).modules.base.options == [
          "journalMaxUse"
          "ntp"
        ]
    ))
    (check "failed boots: chattr is in /usr/bin (efivarfs makes the variable immutable)" (
      baseOnly.links ? "/usr/bin/chattr"
    ))
    (check "failed boots: on a halted boot the trial boot policy's reboot units skip themselves" (
      hasInfix haltSkips baseOnly.units."golconda-emergency-reboot.service"
      && hasInfix haltSkips baseOnly.units."golconda-trial-boot-failed.service"
    ))
  ]
)
++ (
  # The ESP's bootstrap credentials hold for one boot (docs/design/boot.md, "Bootstrap
  # credentials"): golconda-esp-credentials.service removes every *.cred systemd-stub would pass
  # on, once this boot's consumers ran, so a later boot, also after a factory reset, imports none.
  let
    inherit (builtins) attrNames filter;
    baseOnly = compose [ ];
    u = baseOnly.units."golconda-esp-credentials.service";
    program = "/usr/lib/golconda/golconda-esp-credentials";
    wants = "/usr/lib/systemd/system/multi-user.target.wants/golconda-esp-credentials.service";
  in
  [
    (check "esp credentials: the unit runs the program after the first boot's consumers" (
      hasInfix "\nExecStart=${program}\n" u
      && hasInfix "\nType=oneshot\n" u
      && hasInfix "\nRemainAfterExit=yes\n" u
      && hasInfix "\nConditionPathExists=!/etc/initrd-release\n" u
      && hasInfix "\nConditionFirmware=uefi\n" u
      # firstboot writes /etc/hostname from firstboot.hostname, sysusers the passwd.* ones, tmpfiles
      # /root/.ssh/authorized_keys; a crash before they finish keeps the ESP's copy for the next boot
      && hasInfix "\nAfter=systemd-firstboot.service systemd-sysusers.service systemd-tmpfiles-setup.service\n" u
    ))
    (check "esp credentials: multi-user.target wants it, nothing else" (
      baseOnly.links.${wants} == {
        target = "../golconda-esp-credentials.service";
        kind = "explicit";
      }
      && filter (p: hasInfix "golconda-esp-credentials" p) (attrNames baseOnly.links) == [ wants ]
    ))
    (check "esp credentials: the program is /base's file, executable" (
      baseOnly.files.${program}.mode == "0755"
      && baseOnly.files.${program}.text == builtins.readFile ../../modules/base/golconda-esp-credentials
    ))
  ]
)
