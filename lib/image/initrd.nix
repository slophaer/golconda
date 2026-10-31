# lib/image/initrd.nix: the initrd, a zstd cpio around a minimal /usr tree.
#
# initrdTree { imageId; version; platform; buildSystem; pkgs; } → the initrd's /usr tree: /base
#   (systemd, dash, uutils-coreutils, dbus-broker) as lib/system.nix composes it, plus lvm2 and
#   cryptsetup, without the kernel (the UKI carries it); lib/usr-tree.nix builds it as for the
#   system.
#
# initrd { usrTree; imageId; version; buildSystem; pkgs; } → derivation with
#   initrd.cpio.zst
#
# The cpio holds: /usr (the tree), /init -> usr/lib/systemd/systemd, /etc/initrd-release ->
# ../usr/lib/os-release (systemd knows it runs in an initrd by it) with /etc/os-release pointing
# at it, the merged-/usr links /bin /sbin /lib, the empty mount points, and lvm2's
# device-mapper udev rules with {prefix} replaced by /usr (they call dmsetup by absolute path,
# and systemd's libcryptsetup needs them for /dev/mapper/usr). No machine-id, no shadow, no
# static /init: systemd itself is PID 1 and finds the /usr partition by usrhash= (its
# veritysetup and gpt-auto generators).
#
# The cmdline (uki.nix) names systemd by its store path as rdinit=: repkgs binaries map ld.so
# relative to their own path, and before /proc is mounted that path is AT_EXECFN as the kernel
# spelled it; /init is a symlink, so the kernel must be told the real file. The /init link stays
# for anything that looks for it. The path is /usr/nix/store/<systemd>/lib/systemd/systemd; the
# builders spell it at build time (a content-addressed output has no name at evaluation time).
_:
let
  inherit (builtins) filter;
  common = import ./common.nix { };
  usrTreeLib = import ../usr-tree.nix { };
in
{
  # initrdTree { imageId; version; platform; buildSystem; pkgs; } → the initrd's /usr tree:
  # the system mkSystem makes of /base alone (lib/system.nix), plus lvm2 and cryptsetup,
  # minus the kernel.
  initrdTree =
    {
      imageId,
      version,
      platform,
      buildSystem,
      pkgs,
      ...
    }:
    let
      sys = import ../system.nix {
        system = buildSystem;
        platform = platform.name;
        config = {
          "/system" = {
            name = imageId;
            inherit version;
          };
        };
        extra."/system".fragments = [
          {
            name = "initrd";
            packages = [
              pkgs.lvm2 # dmsetup and the dm udev rules (initrd.nu substitutes {prefix})
              pkgs.cryptsetup # veritysetup, for the initrd's own checks
            ];
          }
        ];
      };
    in
    usrTreeLib.usrTree {
      # the kernel is in the UKI, not in the initrd
      composerOutput = sys.composed // {
        packages = filter (p: p != pkgs.linux-kernel) sys.composed.packages;
      };
      inherit platform version buildSystem;
    };

  initrd =
    {
      usrTree,
      imageId,
      version,
      buildSystem,
      pkgs,
      ... # platform and the rest of the shared argument set
    }:
    common.nuDerivation {
      name = "${imageId}_${version}.initrd";
      inherit buildSystem;
      module = "initrd";
      tools = [ pkgs.zstd ];
      attrs = {
        inherit usrTree;
        dmRules = "${pkgs.lvm2}/lib/udev/rules.d";
        # PID 1: checked to exist in the cpio under the path rdinit= names
        inherit (pkgs) systemd;
      };
    };
}
