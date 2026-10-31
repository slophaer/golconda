# lib/image/disk.nix: the GPT disk image, with systemd-repart.
#
# repartDefinitions { } → attrset <name>.conf → INI text: image/repart.nix's build-time
#   definitions (every partition but root, which repart creates on the machine at first boot)
#   with the builder's fields: the ESP's CopyFiles, slot A's CopyBlocks and the two UUIDs
#   systemd derives from the root hash (usr: its first 128 bits, usr-verity: its last 128 bits;
#   systemd-veritysetup-generator(8)). Values the builder knows only at build time stay as
#   {esp} {usr} {verity} {sig} {usrUuid} {verityUuid}, which disk.nu fills in.
#   Rendered with modules/lib/ini.nix.
#
# disk { erofs; verity; uki; imageId; version; platform; buildSystem; pkgs; sbKey; sbCert; }
#   → derivation with
#   disk.raw        GPT: ESP (systemd-boot as EFI/BOOT/BOOT<ARCH>.EFI, signed with the UKI's
#                   Secure Boot key and certificate; loader.conf with the boot policy; the UKI
#                   in EFI/Linux/), usr-a, usr-a-verity, usr-a-verity-sig filled from the images,
#                   the B slots empty, no root partition
#   disk.json       systemd-repart's own listing (--json=pretty) of what it made
#
# The loader is signed with the same db key and certificate as the UKI (image/default.nix
# keys; lib/image/uki.nix): enforcing firmware starts nothing else. loader.conf is written from
# this file's loaderConf, so the policy is one string the tests can read.
#
# systemd-repart --empty=create --size=auto --offline=yes --seed=<from the version>: no loop
# device, no root; the usr slots are 10 GiB each (image/repart.nix), so the file is sparse and
# written straight into the output.
_:
let
  inherit (builtins)
    attrNames
    filter
    listToAttrs
    ;
  common = import ./common.nix { };
  image = import ../../image;
  ini = import ../../modules/lib/ini.nix;

  # the builder's fields per definition; anything else from image/repart.nix is left alone
  builderFields = {
    "00-esp".Partition.CopyFiles = "{esp}:/";
    "10-usr-a".Partition = {
      CopyBlocks = "{usr}";
      UUID = "{usrUuid}";
    };
    "11-usr-a-verity".Partition = {
      CopyBlocks = "{verity}";
      UUID = "{verityUuid}";
    };
    "12-usr-a-verity-sig".Partition.CopyBlocks = "{sig}";
  };
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
rec {
  # The ESP's systemd-boot policy (loader.conf(5), systemd v262.1): the UKI under EFI/Linux is
  # auto-discovered, so there is no entry line; the menu does not wait and the editor is off
  # (an editor would let anyone at the console change the measured cmdline).
  loaderConf = ''
    # Golconda: lib/image/disk.nix; docs/design/boot.md.
    timeout 0
    editor no
  '';

  repartDefinitions =
    _:
    let
      buildTime = filter (n: image.repart.${n}.Partition.Type != "root") (attrNames image.repart);
      withFields =
        n:
        let
          d = image.repart.${n};
          f = builderFields.${n} or { };
        in
        d // { Partition = d.Partition // (f.Partition or { }); };
    in
    listToAttrs (
      map (n: {
        name = "${n}.conf";
        value = ini.render (withFields n);
      }) buildTime
    );

  disk =
    {
      erofs,
      verity,
      uki,
      imageId,
      version,
      platform,
      buildSystem,
      pkgs,
      sbKey,
      sbCert,
    }:
    let
      stem = "${imageId}_${version}";
      ukiName = (import ./uki.nix { }).ukiName { inherit imageId version; };
      uefi = platform.names.uefi;
    in
    common.nuDerivation {
      name = "${stem}.disk";
      inherit buildSystem;
      module = "disk";
      tools = [
        pkgs.systemd # systemd-repart
        pkgs.dosfstools # mkfs.vfat
        pkgs.mtools # mcopy, mmd: how repart fills a vfat offline
      ];
      libs = [
        pkgs.util-linux # systemd-repart: libfdisk, libblkid, libmount
        pkgs.openssl # libcrypto, for the partition UUID derivation
        pkgs.cryptsetup # libcryptsetup, opened when a definition has Verity=
      ];
      attrs = {
        definitions = repartDefinitions { };
        usr = "${erofs}/${stem}.usr.raw";
        verity = "${verity}/${stem}.usr-verity.raw";
        sig = "${verity}/${stem}.usr-verity-sig.raw";
        roothash = "${verity}/roothash";
        uki = "${uki}/${ukiName}";
        inherit ukiName;
        systemdBoot = "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${uefi}.efi";
        bootEntry = "EFI/BOOT/${removableMediaName uefi}";
        inherit loaderConf sbKey sbCert;
        architecture = platform.names.systemd;
        seed = common.uuidOfHex (common.hexOf "${stem}.disk");
        epoch = common.versionToEpoch version;
      };
    };
}
