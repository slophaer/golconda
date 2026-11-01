# Checks of the image chain's pure parts (lib/image) and the /usr tree builder's helpers (lib/usr-tree.nix).
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  hasInfix,
  hasPrefix,
  imageLib,
  usrTreeLib,
  ...
}:
let
  inherit (builtins)
    attrNames
    filter
    isString
    split
    tryEval
    ;
in
[
  # 8. usr-tree library: pure helpers
  (check "usr-tree: stripUsrPrefix strips /usr/ prefix" (
    usrTreeLib.stripUsrPrefix "/usr/lib/foo" == "lib/foo"
    && usrTreeLib.stripUsrPrefix "/usr/bin/jq" == "bin/jq"
  ))
  (check "usr-tree: stripUsrPrefix returns null for non-/usr paths" (
    usrTreeLib.stripUsrPrefix "/etc/foo" == null && usrTreeLib.stripUsrPrefix "/var/lib/x" == null
  ))
  (check "usr-tree: versionToEpoch parses date versions" (
    let
      e1 = usrTreeLib.versionToEpoch "20261031.1";
      e2 = usrTreeLib.versionToEpoch "20261031.2";
    in
    e2 > e1 # revision 2 is later than revision 1
  ))
  (check "usr-tree: versionToEpoch throws on a bad format" (
    let
      bad = v: !(tryEval (usrTreeLib.versionToEpoch v)).success;
    in
    bad "1" && bad "2026.10.31" && bad "20261031" && bad "v1.0.0" && bad "" && !bad "20261031.1"
  ))
  (check "image: versionToEpoch throws on a bad format too" (
    !(tryEval (imageLib.versionToEpoch "1")).success
  ))
  (check "image: versionToEpoch stays inside the date, so no revision aliases a day" (
    let
      epoch = usrTreeLib.versionToEpoch;
      bad = v: !(tryEval (epoch v)).success;
    in
    # month, leap-year and day boundaries
    epoch "20240229.0" - epoch "20240228.0" == 86400
    && epoch "20240301.0" - epoch "20240229.0" == 86400
    && epoch "20250228.0" + 86400 == epoch "20250301.0"
    && epoch "20261031.86399" + 1 == epoch "20261101.0"
    # not dates, or past the day: these would share or pass another day's epoch
    && bad "20260231.1"
    && bad "20250229.1"
    && bad "20261301.1"
    && bad "20261031.86400"
  ))
  # make-relative is tested in lib/usr-tree/test.nu, against the function the
  # builder runs; lib/usr-tree.nix has no second copy.
  (check "usr-tree: renderOsRelease includes version and arch" (
    let
      osRel = usrTreeLib.renderOsRelease {
        imageId = "t";
        version = "20261031.1";
        platform = {
          cpu = "x86_64";
        };
      };
    in
    hasInfix "VERSION_ID=20261031.1" osRel
    && hasInfix "IMAGE_VERSION=20261031.1" osRel
    && hasInfix "ARCHITECTURE=x86_64" osRel
  ))
  # 12. The image chain's pure parts (lib/image)
  (check "image: versionToEpoch is lib/usr-tree.nix's, one function" (
    imageLib.versionToEpoch "20261031.1" == usrTreeLib.versionToEpoch "20261031.1"
    && imageLib.versionToEpoch "20261031.1" == 1793404801
    && imageLib.versionToEpoch "20261031.2" == 1793404802
    && imageLib.versionToEpoch "20261101.1" == 1793404801 + 86400
  ))
  (check "image: the UKI's installed name carries the boot counter" (
    imageLib.ukiName {
      imageId = "golconda";
      version = "20261031.1";
    } == "golconda_20261031.1+3-0.efi"
  ))
  (check "image: a UUID from the first 32 hex digits" (
    imageLib.uuidOfHex "c9c2180678d390a7a13ff0e23149523ce2ec58ab9df04ccdf87de4235b7e0476"
    == "c9c21806-78d3-90a7-a13f-f0e23149523c"
  ))
  (check "image: repart definitions are the build-time partitions with the builder's fields" (
    let
      defs = imageLib.repartDefinitions { version = "20261031.1"; };
      names = attrNames defs;
    in
    names == [
      "00-esp.conf"
      "10-usr-a.conf"
      "11-usr-a-verity.conf"
      "12-usr-a-verity-sig.conf"
      "20-usr-b.conf"
      "21-usr-b-verity.conf"
      "22-usr-b-verity-sig.conf"
    ]
    # root is made on the machine at first boot, not here
    && !(defs ? "30-root.conf")
    # the ESP takes the staged tree; slot A takes the images and the hash-derived UUIDs
    && hasInfix "CopyFiles={esp}:/" defs."00-esp.conf"
    && hasInfix "CopyBlocks={usr}" defs."10-usr-a.conf"
    && hasInfix "UUID={usrUuid}" defs."10-usr-a.conf"
    && hasInfix "CopyBlocks={verity}" defs."11-usr-a-verity.conf"
    && hasInfix "UUID={verityUuid}" defs."11-usr-a-verity.conf"
    && hasInfix "CopyBlocks={sig}" defs."12-usr-a-verity-sig.conf"
    # the B slots are the same size as A and get nothing
    && hasInfix "SizeMinBytes=10G" defs."20-usr-b.conf"
    && !hasInfix "CopyBlocks" defs."20-usr-b.conf"
    # …and carry the empty-slot label: without it dissection fails and gpt-auto mounts nothing
    && hasInfix "Label=_empty" defs."20-usr-b.conf"
    && hasInfix "Label=_empty" defs."21-usr-b-verity.conf"
    && hasInfix "Label=_empty" defs."22-usr-b-verity-sig.conf"
    # image/repart.nix's own fields render as INI (ini.nix: booleans are yes/no)
    && hasInfix "[Partition]\n" defs."10-usr-a.conf"
    && hasInfix "ReadOnly=yes" defs."10-usr-a.conf"
    && hasInfix "Type=usr-verity-sig" defs."12-usr-a-verity-sig.conf"
  ))
  (check "image: os-release carries /system.name as ID and IMAGE_ID" (
    let
      os = usrTreeLib.renderOsRelease {
        version = "20261031.1";
        platform = {
          name = "x86_64-linux";
          cpu = "x86_64";
        };
        imageId = "server";
      };
    in
    hasInfix "ID=server\n" os && hasInfix "IMAGE_ID=server\n" os
  ))
  (check "image: loader.conf turns the editor off and does not wait" (
    let
      conf = imageLib.loaderConf;
      settings = filter (l: l != "" && !(hasPrefix "#" l)) (filter isString (split "\n" conf));
    in
    # loader.conf(5), systemd v262.1: `editor` takes a boolean; the UKI under EFI/Linux is
    # found without an entry line
    settings == [
      "timeout 0"
      "editor no"
    ]
    # one text: the disk step's and the one /base installs in /usr
    && conf == (import ../../image).loader.conf
  ))
  (check "image: the loader fragment puts the signed loader where bootctl looks" (
    let
      platform = {
        names.uefi = "x64";
      };
      loader = {
        type = "derivation";
        outPath = "/loader-out";
      };
      frag = imageLib.loaderFragment { inherit loader platform; };
      p = "/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed";
    in
    # bootctl prefers <name>.efi.signed to the unsigned <name>.efi beside it
    # (bootctl-install.c install_binaries); the store path enters the /usr closure
    attrNames frag.links == [ p ]
    &&
      frag.links.${p} == {
        target = "/loader-out/systemd-bootx64.efi.signed";
        kind = "explicit";
      }
    && frag.packages == [ loader ]
    && imageLib.loaderUsrPath platform == p
  ))
  (check "image: the cmdline template has usrhash and rw, and no ro or volatile" (
    let
      t = (import ../../image).uki.cmdlineTemplate;
    in
    # rw: the initrd mounts the root partition read-only without it, and the ssh host key
    # var unit runs before systemd-remount-fs (docs/design/boot.md)
    hasInfix "usrhash={usrhash}" t && hasInfix " rw " t && !hasInfix " ro " t && !hasInfix "volatile" t
  ))
  # without the option, veritysetup activates /usr unsigned and IPE's dmverity_signature is
  # false for every /usr file (docs/design/trust.md)
  (check "image: the cmdline hands the usr root hash signature to veritysetup" (
    hasInfix "systemd.verity_usr_options=root-hash-signature=base64:{usrhashSig}" (import ../../image)
    .uki.cmdlineTemplate
  ))
]
