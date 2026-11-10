# lib/image/loader.nix: systemd-boot, signed for Secure Boot, in /usr and on the ESP.
#
# loaderParams { platform; pkgs; } → the manifest's `loader` (lib/image/manifest.nix):
#   unsigned   systemd's systemd-boot<uefi>.efi, which the signer signs with the db key
#              (lib/image/loader.nu, systemd-sbsign)
#   usrPath    lib/systemd/boot/efi/systemd-boot<uefi>.efi.signed, relative to the /usr tree:
#              the name bootctl prefers to the unsigned file beside it and the file
#              golconda-loader-update copies to the ESP (modules/base)
#   espPaths   bootctl's layout on the ESP: the primary copy and the removable-media path
#   conf, confPath  image/loader.nix's loader.conf and where systemd-boot reads it
#
# One signature, two places: the signer puts the signed file into its copy of the /usr tree
# before mkfs.erofs, and the same bytes on the ESP. A release therefore ships its loader inside
# the signed, verity-checked /usr, and the machine installs it from there
# (docs/design/bootloader.md). The /usr tree that Nix builds has no file at usrPath.
_:
let
  image = import ../../image;
  fileName = platform: "systemd-boot${platform.names.uefi}.efi.signed";
  usrPath = platform: "/usr/lib/systemd/boot/efi/${fileName platform}";
  # The UEFI removable-media boot path's file name, by the platform's uefi name
  removableMediaName =
    uefi:
    {
      x64 = "BOOTX64.EFI";
      aa64 = "BOOTAA64.EFI";
      riscv64 = "BOOTRISCV64.EFI";
    }
    .${uefi} or (throw "golconda: no removable-media boot name for uefi arch ${uefi}");
in
{
  # the signed loader's file name and its path in /usr, by platform
  loaderFileName = fileName;
  loaderUsrPath = usrPath;

  # The ESP's systemd-boot policy: image/loader.nix, the one text /base installs in /usr too
  loaderConf = image.loader.conf;

  loaderParams =
    { platform, pkgs }:
    let
      uefi = platform.names.uefi;
    in
    {
      unsigned = "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${uefi}.efi";
      # relative to the tree, which is /usr
      usrPath = builtins.replaceStrings [ "/usr/" ] [ "" ] (usrPath platform);
      espPaths = [
        "EFI/systemd/systemd-boot${uefi}.efi"
        "EFI/BOOT/${removableMediaName uefi}"
      ];
      inherit (image.loader) conf confPath usrConfPath;
    };
}
