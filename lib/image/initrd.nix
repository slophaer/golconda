# lib/image/initrd.nix: the initrd, a zstd cpio around a minimal /usr tree.
#
# initrdSystem { imageId; version; platform; buildSystem; pkgs; packagesDir ? null;
#   replaces ? [ ]; } → the mkSystem of the initrd: /base (systemd, dash, uutils-coreutils,
#   dbus-broker) as lib/system.nix composes it, plus lvm2 and cryptsetup. `packagesDir` and
#   `replaces` are the configuration's downstream package directory and its [golconda]
#   replaces, so a replacement reaches the initrd too, under the same opt-in.
# initrdTree (the same arguments) → the initrd's /usr tree: that system without the kernel (the
#   UKI carries it); lib/usr-tree.nix builds it as for the system.
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
# The cmdline (uki.nix) names /init as rdinit=. repkgs binaries find ld.so and their libraries
# relative to their own path, and before /proc is mounted that path is AT_EXECFN as the kernel
# spelled it: the fork's crt-interp and glibc resolve its symlinks (/init -> usr/lib/systemd/
# systemd -> the store) without /proc.
_:
let
  inherit (builtins) filter;
  common = import ./common.nix { };
  usrTreeLib = import ../usr-tree.nix { };

  initrdSystem =
    {
      imageId,
      version,
      platform,
      buildSystem,
      pkgs,
      packagesDir ? null,
      replaces ? [ ],
      ...
    }:
    import ../system.nix {
      system = buildSystem;
      platform = platform.name;
      config = {
        "/system" = {
          name = imageId;
          inherit version;
        };
      }
      // (
        if packagesDir == null then
          { }
        else
          {
            golconda = {
              packages = packagesDir;
              inherit replaces;
            };
          }
      );
      extraFragments = [
        {
          name = "/image/initrd";
          packages = [
            pkgs.lvm2 # dmsetup and the dm udev rules (initrd.nu substitutes {prefix})
            pkgs.cryptsetup # veritysetup, for the initrd's own checks
          ];
          # The initrd reaches sockets.target and sysinit.target, which pull networkd (its
          # socket) and timesyncd through /base's .wants links. sysusers does not run in the
          # initrd, so /base gives those units ConditionPathExists=!/etc/initrd-release.
          # resolved is wanted by multi-user.target only, which the initrd does not reach.
        }
      ];
    };
in
{
  # the system mkSystem makes of /base alone (lib/system.nix), plus lvm2 and cryptsetup
  inherit initrdSystem;

  # initrdTree: the initrd system's /usr tree, without the kernel
  initrdTree =
    args@{
      version,
      platform,
      buildSystem,
      ...
    }:
    let
      sys = initrdSystem args;
    in
    usrTreeLib.usrTree {
      # the kernel is in the UKI, not in the initrd. The initrd's own set: with
      # /system.secureBoot = false the image's kernel is another derivation
      composerOutput = sys.composed // {
        packages = filter (p: p != sys.pkgs.linux-kernel) sys.composed.packages;
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
      };
    };
}
