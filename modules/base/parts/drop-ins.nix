# Part of /base (modules/base/default.nix merges it): the drop-ins for units the
# systemd farm ships. A mask link would collide with the farm, and a condition says
# the real reason. A unit that only systemd's preset enabled needs none: 00-golconda.preset
# turns the preset off. Returns { files; }.
let
  dropIn = text: {
    inherit text;
    mode = "0644";
  };
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
  };
}
