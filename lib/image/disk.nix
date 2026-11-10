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
# diskParams { imageId; version; platform; } → the manifest's `disk` (lib/image/manifest.nix):
#   definitions (the above), architecture, seed (from the version), epoch. The signer
#   (lib/image/disk.nu) runs systemd-repart --empty=create --size=auto --offline=yes --seed: no
#   loop device, no root. It writes
#   disk.raw        GPT: ESP (the signed systemd-boot as EFI/systemd/systemd-boot<arch>.efi and
#                   EFI/BOOT/BOOT<ARCH>.EFI, loader.conf at loader/loader.conf, the UKI in
#                   EFI/Linux/), usr-a, usr-a-verity, usr-a-verity-sig filled from the images,
#                   the B slots empty, no root partition
#   disk.json       systemd-repart's own listing (--json=pretty) of what it made
#   release/        the release under the names image/sysupdate.nix's sources match
#                   (releaseNames): <id>_<v>.usr.<uuid>.raw, <id>_<v>.usr-verity.<uuid>.raw with
#                   the hash-derived UUIDs, <id>_<v>.usr-verity-sig.raw, <id>_<v>.efi,
#                   SHA256SUMS, the index a url-file source reads, and SHA256SUMS.gpg, its
#                   signature with the release key
#
# The usr slots are 10 GiB each (image/repart.nix), so disk.raw is sparse.
_:
let
  inherit (builtins)
    attrNames
    filter
    listToAttrs
    replaceStrings
    stringLength
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
in
rec {
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

  diskParams =
    {
      imageId,
      version,
      platform,
    }:
    {
      definitions = repartDefinitions { inherit version; };
      architecture = platform.names.systemd;
      seed = common.uuidOfHex (common.hexOf "${imageId}_${version}.disk");
      epoch = common.versionToEpoch version;
    };
}
