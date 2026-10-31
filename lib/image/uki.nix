# lib/image/uki.nix: the unified kernel image.
#
# uki { initrd; verity; usrTree; imageId; version; platform; buildSystem; pkgs; sbKey; sbCert;
#       pcrKey; pcrPublicKey; } → derivation with
#   <imageId>_<version>+3-0.efi    the UKI under its boot-counting name (image/default.nix
#                                   bootCounting; systemd-boot decrements, bless-boot renames)
#   cmdline                          what went in, for the record
#
# ukify build (packages/ukify) joins systemd's stub, the kernel from the linux-kernel package,
# the initrd, the cmdline (image/uki.nix's template with usrhash= and the root hash signature
# from the verity step, plus rdinit= as lib/image/initrd.nix explains), the system's os-release
# and the kernel's uname. The kernel trusts the signature only if the firmware db holds its
# signer, so the build checks it against sbCert: the verity step must sign with the db key.
# Secure Boot: systemd-sbsign with sbKey/sbCert. Measured boot: one PCR 11 signature per
# phase path in image/uki.nix's list (ukify --phases), signed with pcrKey, and the built
# .pcrsig section is checked against the list (docs/design/trust.md). Keys are paths; the
# production ones live outside the store (image/default.nix keys); the smoke uses throwaways.
_:
let
  inherit (builtins) toString;
  common = import ./common.nix { };
  image = import ../../image;
in
rec {
  # The installed name: <imageId>_<version>+<triesLeft>-<triesDone>.efi
  ukiName =
    { imageId, version }:
    "${imageId}_${version}+${toString image.bootCounting.triesLeft}-${toString image.bootCounting.triesDone}.efi";

  uki =
    {
      initrd,
      verity,
      usrTree,
      imageId,
      version,
      platform,
      buildSystem,
      pkgs,
      sbKey,
      sbCert,
      pcrKey,
      pcrPublicKey,
      cmdlineExtra ? "", # appended to the template: the smoke's debug flags go here, not in image/
      ...
    }:
    let
      ukiConfig = image.uki;
      uefi = platform.names.uefi;
    in
    common.nuDerivation {
      name = ukiName { inherit imageId version; };
      inherit buildSystem;
      module = "uki";
      tools = [
        pkgs.ukify
        pkgs.systemd # systemd-measure, systemd-sbsign (lib/systemd, on PATH too)
        pkgs.openssl # the root hash signature against sbCert
      ];
      libs = [
        pkgs.openssl # systemd-sbsign, systemd-measure: libcrypto
        pkgs.tpm2-tss # systemd-measure: libtss2-mu for the PCR policy
      ];
      attrs = {
        fileName = ukiName { inherit imageId version; };
        kernel = pkgs.linux-kernel;
        inherit (pkgs) systemd;
        stub = "${pkgs.systemd}/lib/systemd/boot/efi/linux${uefi}.efi.stub";
        initrd = "${initrd}/initrd.cpio.zst";
        roothash = "${verity}/roothash";
        roothashSig = "${verity}/${imageId}_${version}.usr-verity-sig.raw";
        osRelease = "${usrTree}/lib/os-release";
        cmdlineTemplate = "${ukiConfig.cmdlineTemplate} ${cmdlineExtra}";
        phases = ukiConfig.pcrPhases;
        inherit
          sbKey
          sbCert
          pcrKey
          pcrPublicKey
          ;
      };
    };
}
