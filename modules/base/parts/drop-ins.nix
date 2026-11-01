# Part of /base (modules/base/default.nix merges it): the drop-ins for units the
# systemd farm ships. A mask link would collide with the farm, and a condition says
# the real reason. Returns { files; }.
let
  inherit (import ../../lib/text.nix) lines;

  dropIn = text: {
    inherit text;
    mode = "0644";
  };
  # the same [Unit] lines as a drop-in for each of the units
  unitConditions =
    conds: units:
    builtins.listToAttrs (
      map (u: {
        name = "/usr/lib/systemd/system/${u}.d/golconda.conf";
        value = dropIn (lines ([ "[Unit]" ] ++ conds));
      }) units
    );
in
{
  files = {
    # no local login: never prompt; credentials (firstboot.*) still apply
    "/usr/lib/systemd/system/systemd-firstboot.service.d/golconda.conf" = dropIn ''
      [Service]
      ExecStart=
      ExecStart=systemd-firstboot --mute-console=yes
    '';
    "/usr/lib/systemd/system/ldconfig.service.d/golconda.conf" = dropIn ''
      [Unit]
      ConditionPathExists=/usr/bin/ldconfig
    '';
    "/usr/lib/systemd/system/modprobe@.service.d/golconda.conf" = dropIn ''
      [Unit]
      ConditionPathExists=/usr/bin/modprobe
    '';
    # no local login: the image has no agetty, and the gettys would restart without end
    "/usr/lib/systemd/system/getty@.service.d/golconda.conf" = dropIn ''
      [Unit]
      ConditionPathExists=/usr/bin/agetty
    '';
    "/usr/lib/systemd/system/serial-getty@.service.d/golconda.conf" = dropIn ''
      [Unit]
      ConditionPathExists=/usr/bin/agetty
    '';
    # one writer of the ESP's loader: golconda-loader-update.service. bootctl update compares
    # versions, so it skips a loader signed again with a new db key, and it runs at sysinit,
    # before a candidate's health gate (docs/design/bootloader.md)
    "/usr/lib/systemd/system/systemd-boot-update.service.d/golconda.conf" = dropIn ''
      [Unit]
      ConditionPathExists=!/usr/lib/golconda/golconda-loader-update
    '';
  }
  # The initrd is built from /base too (lib/image/initrd.nix), with the .wants links of
  # /base, and it reaches sockets.target and sysinit.target. sysusers does not run there,
  # so these daemons fail at step USER, hit their start limit and stay failed after
  # switch-root.
  //
    unitConditions
      [ "ConditionPathExists=!/etc/initrd-release" ]
      [
        "systemd-networkd.service"
        "systemd-networkd.socket"
        "systemd-timesyncd.service"
      ]
  # systemd's preset enables the sysupdate timers; without a transfer definition (no
  # /system.updateSource) the services fail with "No transfer definitions found"
  //
    unitConditions
      [
        "ConditionDirectoryNotEmpty=|/usr/lib/sysupdate.d"
        "ConditionDirectoryNotEmpty=|/etc/sysupdate.d"
        "ConditionDirectoryNotEmpty=|/run/sysupdate.d"
      ]
      [ "systemd-sysupdate.service" "systemd-sysupdate-reboot.service" ]
  # systemd-coredump --check-requirements needs PIDFD_INFO_COREDUMP_SIGNAL (kernel 6.19);
  # on an older kernel the ExecCondition skips the units, but they are started again
  # until the start limit marks coredumpd failed
  //
    unitConditions
      [ "ConditionKernelVersion=>=6.19" ]
      [
        "systemd-coredumpd.service"
        "systemd-coredump-register.service"
      ];
}
