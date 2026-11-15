# Checks of the image chain's pure parts (lib/image) and the /usr tree builder's helpers (lib/usr-tree.nix).
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  fixturePkgs,
  hasInfix,
  hasPrefix,
  imageLib,
  mkSystemFixture,
  sources,
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
  # lvm2's device-mapper rules exec dmsetup by its compiled-in path, so lvm2 is a farm package
  # (prefix /usr): /base links two of its rules as they are, with nothing to substitute, for the
  # host and the initrd alike (/dev/mapper/usr, dev-mapper-usr.device); 95-dm-notify only answers
  # udev cookies, which libdevmapper does not wait on without udev_sync
  (check "base: lvm2's 10-dm and 13-dm-disk rules and dmsetup, in the host and the initrd" (
    let
      initrd =
        (imageLib.initrdSystem {
          imageId = "t";
          version = "20261031.1";
          pkgs = fixturePkgs;
          inherit sources;
          platform.name = "x86_64-linux";
          buildSystem = "x86_64-linux";
        }).composed;
      host = mkSystemFixture.composed;
      rule = n: {
        target = "${fixturePkgs.lvm2}/lib/udev/rules.d/${n}";
        kind = "explicit";
      };
      hasRules =
        sys:
        sys.links."/usr/lib/udev/rules.d/10-dm.rules" == rule "10-dm.rules"
        && sys.links."/usr/lib/udev/rules.d/13-dm-disk.rules" == rule "13-dm-disk.rules"
        && !(sys.links ? "/usr/lib/udev/rules.d/95-dm-notify.rules")
        && !(sys.links ? "/usr/lib/udev/rules.d")
        && (sys.origins.packages.lvm2 or [ ]) == [ "/base" ];
    in
    fixturePkgs.lvm2.args.prefix == "/usr" && hasRules host && hasRules initrd
  ))
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
  # make-relative is tested in tests/usr-tree/test.nu, against the function the
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
    hasInfix "VERSION_ID=\"20261031.1\"\n" osRel
    && hasInfix "IMAGE_VERSION=\"20261031.1\"\n" osRel
    && hasInfix "ARCHITECTURE=\"x86_64\"\n" osRel
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
    hasInfix "ID=\"server\"\n" os && hasInfix "IMAGE_ID=\"server\"\n" os
  ))
  (check "image: os-release quotes every value so a shell can source it" (
    let
      os = usrTreeLib.renderOsRelease {
        version = "20261031.1";
        platform = {
          name = "x86_64-linux";
          cpu = "x86_64";
        };
        imageId = "a b\"c$d`e\\f";
      };
      lines = filter (l: isString l && l != "") (split "\n" os);
    in
    hasInfix "PRETTY_NAME=\"Golconda 20261031.1\"\n" os
    && hasInfix "IMAGE_ID=\"a b\\\"c\\$d\\`e\\\\f\"\n" os
    && builtins.all (l: builtins.match "[A-Z_]+=\".*\"" l != null) lines
  ))
  (check "image: loader.conf turns the editor off, does not wait, enrols on the first start only" (
    let
      settings = conf: filter (l: l != "" && !(hasPrefix "#" l)) (filter isString (split "\n" conf));
      image = (import ../../image).loader;
    in
    # loader.conf(5), systemd v262.1: `editor` takes a boolean; the UKI under EFI/Linux is
    # found without an entry line. The copy in /usr, which golconda-loader-update puts on the
    # ESP after the first good boot, enrols nothing: `off` (the default `if-safe` enrols in a
    # virtual machine, `manual` offers menu entries)
    settings imageLib.loaderConf == [
      "timeout 0"
      "editor no"
      "secure-boot-enroll off"
    ]
    # the first disk's ESP: `force` enrols loader/keys/auto in Setup Mode, also on hardware
    # (src/boot/secure-boot.c)
    &&
      settings image.firstConf == [
        "timeout 0"
        "editor no"
        "secure-boot-enroll force"
      ]
    # one text: the one /base installs in /usr and golconda-loader-update keeps on the ESP
    && imageLib.loaderConf == image.conf
  ))
  (check "image: the signer puts the signed loader where bootctl looks, and on the ESP" (
    let
      platform = {
        names.uefi = "x64";
      };
      pkgs.systemd = "/systemd";
      params =
        secureBoot: microsoftKeys:
        imageLib.loaderParams {
          inherit
            platform
            pkgs
            secureBoot
            microsoftKeys
            ;
        };
      l = params true true;
      p = "/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed";
    in
    # bootctl prefers <name>.efi.signed to the unsigned <name>.efi beside it
    # (bootctl-install.c install_binaries); the signer signs systemd's loader and puts it at
    # usrPath in its copy of the /usr tree (lib/image/sign.nu)
    imageLib.loaderUsrPath platform == p
    && l.usrPath == "lib/systemd/boot/efi/systemd-bootx64.efi.signed"
    && l.unsigned == "/systemd/lib/systemd/boot/efi/systemd-bootx64.efi"
    &&
      l.espPaths == [
        "EFI/systemd/systemd-bootx64.efi"
        "EFI/BOOT/BOOTX64.EFI"
      ]
    && l.conf == imageLib.loaderConf
    # the first disk's ESP arms the enrolment only where there is something to enrol
    && l.firstConf == (import ../../image).loader.firstConf
    && (params false true).firstConf == imageLib.loaderConf
    # the enrolment files go where systemd-boot looks for the set named `auto`: the key set's
    # set with Microsoft's keys by default, the one without them on request, and none for an
    # image without Secure Boot, whose firmware must not start checking by itself
    && l.enrolPath == "loader/keys/auto"
    && l.enrol
    && l.enrolSet == "microsoft"
    && (params true false).enrolSet == "golconda"
    && !(params false true).enrol
  ))
  # the removable-media name is bootctl's rule, "BOOT" and the EFI arch upper-cased
  # (bootctl-install.c), on both sides: the signer's ESP and golconda-loader-update, with no table
  (check "image: the removable-media path is BOOT<ARCH>.EFI for every EFI arch, by one rule" (
    let
      removable =
        uefi:
        builtins.elemAt
          (imageLib.loaderParams {
            platform.names.uefi = uefi;
            pkgs.systemd = "/systemd";
            secureBoot = true;
            microsoftKeys = true;
          }).espPaths
          1;
      script = builtins.readFile ../../modules/base/golconda-loader-update;
    in
    removable "x64" == "EFI/BOOT/BOOTX64.EFI"
    && removable "aa64" == "EFI/BOOT/BOOTAA64.EFI"
    && removable "riscv64" == "EFI/BOOT/BOOTRISCV64.EFI"
    && removable "ia32" == "EFI/BOOT/BOOTIA32.EFI"
    && !(hasInfix "BOOTX64.EFI" script)
    && hasInfix "tr '[:lower:]' '[:upper:]'" script
  ))
  (check "image: the signer's parameters come from the version, not from a key" (
    let
      a = {
        imageId = "t";
        version = "20261031.1";
      };
      e = imageLib.erofsParams a;
      v = imageLib.verityParams a;
    in
    e.fileName == "t_20261031.1.usr.raw"
    && e.epoch == imageLib.versionToEpoch "20261031.1"
    && e.uuid == imageLib.uuidOfHex (imageLib.hexOf "t_20261031.1.usr.raw")
    # the whole record: compression is the one fixed parameter
    &&
      builtins.attrNames e == [
        "compression"
        "epoch"
        "fileName"
        "uuid"
      ]
    && e.compression == "lz4hc"
    && v.hashFile == "t_20261031.1.usr-verity.raw"
    && v.sigFile == "t_20261031.1.usr-verity-sig.raw"
    && v.salt == imageLib.hexOf "t_20261031.1.usr-verity.raw"
  ))
  (check "image: the cmdline template has usrhash and rw, and no ro or volatile" (
    let
      t = (import ../../image).uki.cmdlineTemplate;
    in
    # rw: the initrd mounts the root partition read-only without it, and PID 1 must write
    # /etc/machine-id before systemd-remount-fs runs (docs/design/boot.md)
    hasInfix "usrhash={usrhash}" t && hasInfix " rw " t && !hasInfix " ro " t && !hasInfix "volatile" t
  ))
  # without the option, veritysetup activates /usr unsigned and IPE's dmverity_signature is
  # false for every /usr file (docs/design/trust.md)
  (check "image: the cmdline hands the usr root hash signature to veritysetup" (
    hasInfix "systemd.verity_usr_options=root-hash-signature=base64:{usrhashSig}" (import ../../image)
    .uki.cmdlineTemplate
  ))
]
