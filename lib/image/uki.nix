# The unified kernel image; image/uki.nix has the command line template and the phase paths.
#
# ukiName { imageId; version; } -> <imageId>_<version>+3-0.efi, the UKI's boot-counting name.
# ukiParams { initrd; usrTree; imageId; version; platform; pkgs; cmdlineExtra ? ""; } -> the
#   manifest's `uki` (lib/image/manifest.nix). The signer (lib/image/uki.nu) runs ukify with it:
#   the root hash signature exists only after the erofs image. The kernel checks that signature
#   against the db certificate built into it, and the signer checks it against the same
#   certificate (docs/design/trust.md).
_:
let
  inherit (builtins) toString;
  image = import ../../image;
in
rec {
  # The installed name: <imageId>_<version>+<triesLeft>-<triesDone>.efi
  ukiName =
    { imageId, version }:
    "${imageId}_${version}+${toString image.bootCounting.triesLeft}-${toString image.bootCounting.triesDone}.efi";

  ukiParams =
    {
      initrd,
      usrTree,
      imageId,
      version,
      platform,
      pkgs,
      cmdlineExtra ? "", # appended to the template: debug flags go here, not in image/
      ...
    }:
    {
      fileName = ukiName { inherit imageId version; };
      kernel = "${pkgs.linux-kernel}";
      systemd = "${pkgs.systemd}";
      stub = "${pkgs.systemd}/lib/systemd/boot/efi/linux${platform.names.uefi}.efi.stub";
      initrd = "${initrd}/initrd.cpio.zst";
      osRelease = "${usrTree}/lib/os-release";
      cmdlineTemplate = "${image.uki.cmdlineTemplate} ${cmdlineExtra}";
      phases = image.uki.pcrPhases;
    };
}
