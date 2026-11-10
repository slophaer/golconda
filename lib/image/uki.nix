# lib/image/uki.nix: the unified kernel image.
#
# ukiName { imageId; version; } → <imageId>_<version>+3-0.efi, the UKI under its boot-counting
#   name (image/default.nix bootCounting; systemd-boot decrements, bless-boot renames)
#
# ukiParams { initrd; usrTree; imageId; version; platform; pkgs; cmdlineExtra ? ""; } → the
#   manifest's `uki` (lib/image/manifest.nix): the kernel from the linux-kernel package, systemd's
#   stub and tools, the initrd, the system's os-release, image/uki.nix's cmdline template and
#   phase list. The signer (lib/image/uki.nu) runs ukify build: the cmdline gets usrhash= and the
#   root hash signature, which exist only after the signer made the erofs image, plus rdinit= as
#   lib/image/initrd.nix explains. Secure Boot: systemd-sbsign with the db key. Measured boot: one
#   PCR 11 signature per phase path (ukify --phases), with the PCR key; the built .pcrsig section
#   is checked against the list (docs/design/trust.md). The kernel trusts the root hash signature
#   only if the firmware db holds its signer, so the signer checks it against the db certificate.
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
