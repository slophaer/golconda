# lib/image: from a /usr tree to a bootable disk image, with repkgs packages only.
#
# One derivation per step, each a nushell builder over structured attrs (common.nix):
#   erofs    lib/usr-tree.nix's output → <id>_<version>.usr.raw           (erofs.nix)
#   verity   the hash tree, root hash and the signed usr-verity-sig partition (verity.nix)
#   initrd   a minimal /usr tree as a zstd cpio, systemd as PID 1           (initrd.nix)
#   uki      kernel + initrd + cmdline, Secure Boot and PCR 11 signed       (uki.nix)
#   disk     GPT with the ESP and the A/B slots, systemd-repart             (disk.nix)
# and the smoke's throwaway keys (throwawayKeys). The pure parts (ukiName, repartDefinitions,
# versionToEpoch) are exported for nix/tests.nix.
#
# docs/reference/image.md describes the artifacts; docs/design/{layout,boot,trust}.md say why.
_:
let
  common = import ./common.nix { };
in
(import ./erofs.nix { })
// (import ./verity.nix { })
// (import ./initrd.nix { })
// (import ./uki.nix { })
// (import ./disk.nix { })
// (import ./smoke.nix { })
// {
  inherit (common) versionToEpoch uuidOfHex hexOf;

  # throwawayKeys { buildSystem; pkgs; } → derivation with the three key pairs of
  # image/default.nix keys (Secure Boot db, verity, PCR policy), self-signed, made with openssl
  # inside the store. For the smoke only: a production key never enters the store.
  throwawayKeys =
    { buildSystem, pkgs }:
    common.nuDerivation {
      name = "golconda-throwaway-keys";
      inherit buildSystem;
      module = "keys";
      tools = [ pkgs.openssl ];
    };
}
