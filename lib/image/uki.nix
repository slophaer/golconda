# lib/image/uki.nix: the unified kernel image.
#
# uki { initrd; verity; usrTree; imageId; version; platform; buildSystem; pkgs; sbKey; sbCert;
#       pcrKey; pcrPublicKey; } → derivation with
#   <imageId>_<version>+3-0.efi    the UKI under its boot-counting name (image/default.nix
#                                   bootCounting; systemd-boot decrements, bless-boot renames)
#   cmdline                          what went in, for the record
#
# ukify build (packages/ukify) joins systemd's stub, the kernel from the linux-kernel package,
# the initrd, the cmdline (image/uki.nix's template with usrhash= from the verity step, plus
# rdinit= as lib/image/initrd.nix explains), the system's os-release and the kernel's uname.
# Secure Boot: systemd-sbsign with sbKey/sbCert. Measured boot: the PCR 11 policy for
# image/uki.nix's phases, signed with pcrKey (docs/design/trust.md). Keys are paths; the
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
      noInitrd ? false, # PROTOTYPE: dm-mod.create= root, no --initrd, pcrsig.json for the ESP
      phases ? null,
      cmdlineExtra ? "", # appended to the template; the smoke's stand-ins go here, not in image/
      # ({dlopenPath} in it becomes the store lib directories of the tree's dlopen links)
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
        initrd = if noInitrd then null else "${initrd}/initrd.cpio.zst";
        inherit noInitrd;
        verityTable = "${verity}/table.json";
        roothash = "${verity}/roothash";
        osRelease = "${usrTree}/lib/os-release";
        inherit usrTree; # for {dlopenPath} (uki.nu)
        cmdlineTemplate = "${ukiConfig.cmdlineTemplate} ${cmdlineExtra}";
        phases = if phases != null then phases else ukiConfig.pcrPhases;
        inherit
          sbKey
          sbCert
          pcrKey
          pcrPublicKey
          ;
      };
    };
}
