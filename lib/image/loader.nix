# lib/image/loader.nix: systemd-boot, signed for Secure Boot, in /usr and on the ESP.
#
# loader { platform; buildSystem; pkgs; sbKey; sbCert; ... } → derivation with
#   systemd-boot<uefi>.efi.signed   systemd's loader signed by systemd-sbsign with the db key and
#                                   certificate the UKI is signed with (lib/image/uki.nix)
#
# loaderFragment { loader; platform; } → a /system fragment that puts the signed loader in /usr at
#   /usr/lib/systemd/boot/efi/systemd-boot<uefi>.efi.signed, the name bootctl prefers to the
#   unsigned file beside it. Give it to mkSystem as extra."/system".fragments.
#
# One signature, two places: the disk step (lib/image/disk.nix) puts the same file on the ESP and
# fails unless the /usr tree carries the same bytes. A release therefore ships its loader inside
# the signed, verity-checked /usr.
_:
let
  common = import ./common.nix { };

  fileName = platform: "systemd-boot${platform.names.uefi}.efi.signed";
  usrPath = platform: "/usr/lib/systemd/boot/efi/${fileName platform}";
in
{
  # the signed loader's file name and its path in /usr, by platform
  loaderFileName = fileName;
  loaderUsrPath = usrPath;

  loader =
    {
      platform,
      buildSystem,
      pkgs,
      sbKey,
      sbCert,
      ...
    }:
    common.nuDerivation {
      name = "golconda-${fileName platform}";
      inherit buildSystem;
      module = "loader";
      tools = [ pkgs.systemd ]; # systemd-sbsign
      libs = [ pkgs.openssl ];
      attrs = {
        systemdBoot = "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${platform.names.uefi}.efi";
        fileName = fileName platform;
        inherit sbKey sbCert;
      };
    };

  loaderFragment =
    { loader, platform }:
    {
      name = "/image/loader";
      # the store path enters the /usr closure; the link names it
      packages = [ loader ];
      links.${usrPath platform} = {
        target = "${loader}/${fileName platform}";
        kind = "explicit";
      };
    };
}
