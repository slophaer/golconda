# Part of /base (modules/base/default.nix merges it): the drop-ins for units the
# systemd farm ships. A mask link would collide with the farm, and a condition says
# the real reason. A unit that only systemd's preset enabled needs none: 00-golconda.preset
# turns the preset off. Returns { files; }.
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
    # no local login: the image has no agetty, and the serial getty that systemd-getty-generator
    # pulls in for console=ttyS0 would restart without end
    "/usr/lib/systemd/system/serial-getty@.service.d/golconda.conf" = dropIn ''
      [Unit]
      ConditionPathExists=/usr/bin/agetty
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
        # not a daemon, but the initrd stays as it was: the host runs it at its own sysinit
        "systemd-network-generator.service"
      ];
}
