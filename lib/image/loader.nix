# lib/image/loader.nix: systemd-boot, signed for Secure Boot, in /usr and on the ESP.
#
# loaderParams { platform; pkgs; secureBoot; microsoftKeys; } -> the manifest's `loader`
# (lib/image/manifest.nix): `unsigned`, the systemd-boot the signer signs with the db key
# (lib/image/loader.nu); `usrPath`, where the signed file goes in the /usr tree (the name bootctl
# prefers; golconda-loader-update copies it to the ESP); `espPaths`, bootctl's layout on the ESP;
# `conf` and `firstConf`, the loader.conf of /usr and the armed one of the first disk's ESP
# (image/loader.nix); `enrol`, `enrolSet` and `enrolPath`, whether the signer copies the key set's
# enrolment files and which set. An image for a host without Secure Boot must not turn the
# firmware's checks on by itself. The signed loader is in the signed, verity-checked /usr and on
# the ESP, from one signature (docs/design/bootloader.md).
_:
let
  image = import ../../image;
  lower = builtins.genList (i: builtins.substring i 1 "abcdefghijklmnopqrstuvwxyz") 26;
  upper = builtins.genList (i: builtins.substring i 1 "ABCDEFGHIJKLMNOPQRSTUVWXYZ") 26;
  fileName = platform: "systemd-boot${platform.names.uefi}.efi.signed";
  usrPath = platform: "/usr/lib/systemd/boot/efi/${fileName platform}";
  # The UEFI removable-media boot path's file name, by the platform's uefi name: bootctl's rule,
  # "BOOT" and the EFI arch upper-cased (src/bootctl/bootctl-install.c). golconda-loader-update
  # applies the same rule to the name of the loader in /usr.
  removableMediaName = uefi: "BOOT${builtins.replaceStrings lower upper uefi}.EFI";
in
{
  # the signed loader's file name and its path in /usr, by platform
  loaderFileName = fileName;
  loaderUsrPath = usrPath;

  # The ESP's systemd-boot policy: image/loader.nix, the one text /base installs in /usr too
  loaderConf = image.loader.conf;

  loaderParams =
    {
      platform,
      pkgs,
      secureBoot,
      microsoftKeys,
    }:
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
      inherit (image.loader)
        conf
        confPath
        usrConfPath
        enrolPath
        ;
      enrol = secureBoot;
      firstConf = if secureBoot then image.loader.firstConf else image.loader.conf;
      enrolSet = if microsoftKeys then "microsoft" else "golconda";
    };
}
