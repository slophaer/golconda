# lib/image/disk.nix: the GPT disk image, with systemd-repart.
#
# repartDefinitions { version } -> <name>.conf -> INI text: the build-time definitions of
#   image/repart.nix (every partition but root) with the builder's fields: the ESP's CopyFiles,
#   slot A's labels, CopyBlocks and the two UUIDs derived from the root hash. Values known only
#   at build time stay as {esp} {usr} {verity} {sig} {usrUuid} {verityUuid}, which disk.nu fills in.
# diskParams { imageId; version; platform; } -> the manifest's `disk` (lib/image/manifest.nix).
#   The signer (lib/image/disk.nu) runs systemd-repart --offline=yes: no loop device, no root.
#   The files it writes (disk.raw, disk.json, release/): docs/reference/image.md.
# The usr slots are 10 GiB each (image/repart.nix), so disk.raw is sparse.
_:
let
  inherit (builtins)
    attrNames
    filter
    fromJSON
    head
    listToAttrs
    match
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
      epoch = (import ../version.nix { }).toEpoch version;
      inherit espBytes;
    };

  # the ESP's size in bytes, from image/repart.nix (`<n>M`, MiB as repart reads it)
  espBytes =
    let
      size = image.repart."00-esp".Partition.SizeMaxBytes;
      mib = match "([0-9]+)M" size;
    in
    if mib == null then
      throw "golconda: the ESP's SizeMaxBytes '${size}' in image/repart.nix is not <n>M"
    else
      fromJSON (head mib) * 1024 * 1024;
}
