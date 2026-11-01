# lib/image/disk.nix: the GPT disk image, with systemd-repart.
#
# repartDefinitions { version } → attrset <name>.conf → INI text: image/repart.nix's build-time
#   definitions (every partition but root, which repart creates on the machine at first boot)
#   with the builder's fields: the ESP's CopyFiles, slot A's labels (slotLabel: the sysupdate
#   target patterns of image/sysupdate.nix with the version), CopyBlocks and the two UUIDs
#   systemd derives from the root hash (usr: its first 128 bits, usr-verity: its last 128 bits;
#   systemd-veritysetup-generator(8)). Values the builder knows only at build time stay as
#   {esp} {usr} {verity} {sig} {usrUuid} {verityUuid}, which disk.nu fills in.
#   Rendered with modules/lib/ini.nix.
#
# disk { erofs; verity; uki; loader; usrTree; imageId; version; platform; buildSystem; pkgs; }
#   → derivation with
#   disk.raw        GPT: ESP (the signed systemd-boot of lib/image/loader.nix as
#                   EFI/systemd/systemd-boot<arch>.efi and EFI/BOOT/BOOT<ARCH>.EFI, loader.conf
#                   at loader/loader.conf, the UKI in EFI/Linux/), usr-a, usr-a-verity,
#                   usr-a-verity-sig filled from the images, the B slots empty, no root partition
#   disk.json       systemd-repart's own listing (--json=pretty) of what it made
#   release/        the release under the names image/sysupdate.nix's sources match
#                   (releaseNames): <id>_<v>.usr.<uuid>.raw, <id>_<v>.usr-verity.<uuid>.raw with
#                   the hash-derived UUIDs, <id>_<v>.usr-verity-sig.raw, <id>_<v>.efi, each a
#                   symlink to its step's output, and SHA256SUMS, the index a url-file source reads
#
# The loader is the file the /usr tree carries (lib/image/loader.nix loaderFragment), signed with
# the UKI's db key: disk.nu fails unless usrTree has the same bytes at the same name, and unless
# its /usr/lib/golconda/loader.conf is loaderConf. So the ESP starts as the machine's
# golconda-loader-update would leave it (modules/base, docs/design/bootloader.md).
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
    replaceStrings
    stringLength
    substring
    ;
  common = import ./common.nix { };
  image = import ../../image;
  ini = import ../../modules/lib/ini.nix;

  # the builder's fields per definition; anything else from image/repart.nix is left alone
  builderFields = version: {
    "00-esp".Partition.CopyFiles = "{esp}:/";
    "10-usr-a".Partition = {
      Label = slotLabel "usr" version;
      CopyBlocks = "{usr}";
      UUID = "{usrUuid}";
    };
    "11-usr-a-verity".Partition = {
      Label = slotLabel "usr-verity" version;
      CopyBlocks = "{verity}";
      UUID = "{verityUuid}";
    };
    "12-usr-a-verity-sig".Partition = {
      Label = slotLabel "usr-verity-sig" version;
      CopyBlocks = "{sig}";
    };
  };

  # An installed slot's GPT label: the sysupdate target pattern (image/sysupdate.nix `slots`) with
  # the version, how sysupdate recognizes the installed instance. GPT holds 36 characters.
  slotLabel =
    type: version:
    let
      label = replaceStrings [ "@v" ] [ version ] image.sysupdate.slots.${type}.label;
    in
    if stringLength label <= 36 then
      label
    else
      throw "golconda: partition label '${label}' is longer than GPT's 36 characters";
  removePrefix =
    p: s:
    if substring 0 (stringLength p) s == p then
      substring (stringLength p) (stringLength s - stringLength p) s
    else
      throw "golconda: '${s}' does not start with '${p}'";
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
  # The ESP's systemd-boot policy: image/loader.nix, the one text /base installs in /usr too
  loaderConf = image.loader.conf;
  inherit slotLabel;

  # releaseNames { imageId; version; } → { usr; verity; sig; uki; }: the release file names, the
  # sysupdate source patterns (image/sysupdate.nix) with the version. `@u` stays for disk.nu, which
  # puts in the UUID derived from the root hash.
  releaseNames =
    { imageId, version }:
    let
      t = image.sysupdate { inherit imageId; };
      name = transfer: replaceStrings [ "@v" ] [ version ] t.${transfer}.Source.MatchPattern;
    in
    {
      usr = name "10-usr";
      verity = name "20-usr-verity";
      sig = name "30-usr-verity-sig";
      uki = name "40-uki";
    };

  repartDefinitions =
    { version }:
    let
      buildTime = filter (n: image.repart.${n}.Partition.Type != "root") (attrNames image.repart);
      withFields =
        n:
        let
          d = image.repart.${n};
          f = (builderFields version).${n} or { };
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
      loader,
      usrTree,
    }:
    let
      stem = "${imageId}_${version}";
      ukiName = (import ./uki.nix { }).ukiName { inherit imageId version; };
      loaderLib = import ./loader.nix { };
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
        definitions = repartDefinitions { inherit version; };
        usr = "${erofs}/${stem}.usr.raw";
        verity = "${verity}/${stem}.usr-verity.raw";
        sig = "${verity}/${stem}.usr-verity-sig.raw";
        roothash = "${verity}/roothash";
        uki = "${uki}/${ukiName}";
        inherit ukiName;
        release = releaseNames { inherit imageId version; };
        loader = "${loader}/${loaderLib.loaderFileName platform}";
        # the same file in the /usr tree, and the loader.conf /base put there
        usrLoader = "${usrTree}/${removePrefix "/usr/" (loaderLib.loaderUsrPath platform)}";
        usrLoaderConf = "${usrTree}/${removePrefix "/usr/" image.loader.usrConfPath}";
        # bootctl's layout: the primary copy, and the removable-media path firmware starts
        loaderPaths = [
          "EFI/systemd/systemd-boot${uefi}.efi"
          "EFI/BOOT/${removableMediaName uefi}"
        ];
        loaderConfPath = image.loader.confPath;
        inherit loaderConf;
        architecture = platform.names.systemd;
        seed = common.uuidOfHex (common.hexOf "${stem}.disk");
        epoch = common.versionToEpoch version;
      };
    };
}
