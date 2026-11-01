# Checks of sysupdate and the disk builder: one naming contract (image/sysupdate.nix `slots`).
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  hasInfix,
  imageLib,
  ...
}:
# sysupdate and the disk builder: one naming contract (image/sysupdate.nix `slots`)
let
  inherit (builtins)
    all
    attrNames
    elemAt
    match
    replaceStrings
    stringLength
    tryEval
    ;
  sysupdate = import ../../image/sysupdate.nix;
  transfers = sysupdate { imageId = "golconda-server"; };
  version = "20261031.1";
  defs = imageLib.repartDefinitions { inherit version; };
  partitionTransfers = {
    usr = "10-usr";
    usr-verity = "20-usr-verity";
    usr-verity-sig = "30-usr-verity-sig";
  };
  slotA = {
    usr = "10-usr-a.conf";
    usr-verity = "11-usr-a-verity.conf";
    usr-verity-sig = "12-usr-a-verity-sig.conf";
  };
  # a sysupdate pattern as a regex, as sysupdate-pattern.c reads it: @v a version, @u a UUID
  patternRegex =
    p:
    replaceStrings
      [ "@v" "@u" "." "+" ]
      [
        "([0-9A-Za-z.~^_-]+)"
        "([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
        "\\."
        "\\+"
      ]
      p;
  # the label an INI definition sets
  labelOf =
    text:
    let
      m = match ".*\nLabel=([^\n]*)\n.*" text;
    in
    if m == null then null else elemAt m 0;
  kinds = attrNames partitionTransfers;
in
[
  (check "sysupdate: each partition transfer finds its slot by a short versioned label" (
    all (
      t:
      let
        target = transfers.${partitionTransfers.${t}}.Target;
      in
      target.MatchPattern == sysupdate.slots.${t}.label
      && target.MatchPartitionType == t
      && hasInfix "@v" target.MatchPattern
      # not the source's artifact name, which systemd would inherit without a target pattern
      && target.MatchPattern != transfers.${partitionTransfers.${t}}.Source.MatchPattern
      && !hasInfix "golconda-server" target.MatchPattern
      && hasInfix "\nMatchPattern=${target.MatchPattern}\n" (
        (import ../../modules/lib/ini.nix).render transfers.${partitionTransfers.${t}}
      )
    ) kinds
  ))
  (check "image: slot A is labelled with the installed version, sysupdate reads it back" (
    all (
      t:
      let
        label = labelOf defs.${slotA.${t}};
        m = match (patternRegex sysupdate.slots.${t}.label) label;
      in
      label == imageLib.slotLabel t version && m != null && elemAt m 0 == version
    ) kinds
    && labelOf defs."10-usr-a.conf" == "usr_20261031.1"
    # the B slots stay free
    && labelOf defs."20-usr-b.conf" == "_empty"
    && labelOf defs."21-usr-b-verity.conf" == "_empty"
    && labelOf defs."22-usr-b-verity-sig.conf" == "_empty"
  ))
  (check "image: a release label fits GPT's 36 characters, a longer one throws" (
    # the longest kind with a twelve-digit counter: 36 exactly
    stringLength (imageLib.slotLabel "usr-verity-sig" "20261031.999999999999") == 36
    && !(tryEval (imageLib.slotLabel "usr-verity-sig" "20261031.9999999999999")).success
    && all (t: stringLength (imageLib.slotLabel t version) <= 36) kinds
  ))
  (check "sysupdate: the data and hash artifacts carry the hash-derived UUID, the target takes it" (
    let
      src = t: transfers.${partitionTransfers.${t}}.Source.MatchPattern;
      target = t: transfers.${partitionTransfers.${t}}.Target;
    in
    hasInfix "@u" (src "usr")
    && hasInfix "@u" (src "usr-verity")
    # the signature has no hash-derived UUID
    && !hasInfix "@u" (src "usr-verity-sig")
    # a fixed PartitionUUID= would describe one release only, and override @u
    && all (t: !(target t ? PartitionUUID)) kinds
    # sysupdate keeps a slot's flags: the free usr slot has slot A's (repart marks verity
    # partitions read-only by itself)
    && hasInfix "ReadOnly=yes" defs."10-usr-a.conf"
    && hasInfix "ReadOnly=yes" defs."20-usr-b.conf"
    && hasInfix "GrowFileSystem=no" defs."20-usr-b.conf"
  ))
  (check "sysupdate: the UKI lands on the boot partition, not under / of the root" (
    transfers."40-uki".Target.PathRelativeTo == "boot"
    && transfers."40-uki".Target.Path == "/EFI/Linux"
    && hasInfix "\nPathRelativeTo=boot\n" ((import ../../modules/lib/ini.nix).render transfers."40-uki")
  ))
  (check "sysupdate: the UKI counters are the release's boot counter, and the source has none" (
    let
      inherit (import ../../image/default.nix) bootCounting;
      uki = transfers."40-uki";
    in
    uki.Target.TriesLeft == bootCounting.triesLeft
    && uki.Target.TriesDone == bootCounting.triesDone
    && uki.Source.MatchPattern == "golconda-server_@v.efi"
    && !(hasInfix "+" uki.Source.MatchPattern)
  ))
  (check "image: the release UKI has no boot counter; the installed name does" (
    let
      release = imageLib.releaseNames {
        imageId = "golconda-server";
        inherit version;
      };
      installed = imageLib.ukiName {
        imageId = "golconda-server";
        inherit version;
      };
    in
    release.uki == "golconda-server_${version}.efi"
    && installed == "golconda-server_${version}+3-0.efi"
    && !(hasInfix "+" release.uki)
  ))
  (check "image: the release names are what the sysupdate sources match, version and UUID" (
    let
      uuid = imageLib.uuidOfHex (imageLib.hexOf "root hash");
      names = imageLib.releaseNames {
        imageId = "golconda-server";
        inherit version;
      };
      fill = replaceStrings [ "@u" ] [ uuid ];
      matches =
        transfer: file: match (patternRegex transfers.${transfer}.Source.MatchPattern) (fill file);
    in
    matches "10-usr" names.usr == [
      version
      uuid
    ]
    &&
      matches "20-usr-verity" names.verity == [
        version
        uuid
      ]
    && matches "30-usr-verity-sig" names.sig == [ version ]
    && matches "40-uki" names.uki == [ version ]
    && fill names.usr == "golconda-server_20261031.1.usr.${uuid}.raw"
    # no file matches another transfer's source
    && matches "10-usr" names.verity == null
    && matches "20-usr-verity" names.usr == null
    && matches "30-usr-verity-sig" names.verity == null
  ))
]
