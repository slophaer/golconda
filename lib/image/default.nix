# lib/image: from a /usr tree to a bootable disk image, with repkgs packages only.
#
# One derivation per step, each a nushell builder over structured attrs (common.nix):
#   erofs    lib/usr-tree.nix's output → <id>_<version>.usr.raw           (erofs.nix)
#   verity   the hash tree, root hash and the signed usr-verity-sig partition (verity.nix)
#   initrd   a minimal /usr tree as a zstd cpio, systemd as PID 1           (initrd.nix)
#   uki      kernel + initrd + cmdline, Secure Boot and PCR 11 signed       (uki.nix)
#   loader   systemd-boot signed with the UKI's key, for /usr and the ESP   (loader.nix)
#   disk     GPT with the ESP and the A/B slots, systemd-repart; signs SHA256SUMS (disk.nix)
#   index    the release key's public half, the keyring of the signed index (index.nix)
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
// (import ./loader.nix { })
// (import ./disk.nix { })
// (import ./index.nix { })
// (import ./smoke.nix { })
// {
  inherit (common) versionToEpoch uuidOfHex hexOf;

  # throwawayKeys { buildSystem; pkgs; variant ? null; } → derivation with the key pairs for
  # the smoke: the Secure Boot db (it also signs the verity root hash and the loader) and the
  # PCR policy key, made with openssl. All self-signed, all made inside the store. For the smoke
  # only: a production key never enters the store. A `variant` is a second, different set (its
  # name and the certificates' CN carry it): the key rotation test signs the next release with
  # it (docs/design/bootloader.md).
  throwawayKeys =
    {
      buildSystem,
      pkgs,
      variant ? null,
    }:
    common.nuDerivation {
      name = "golconda-throwaway-keys" + (if variant == null then "" else "-${variant}");
      inherit buildSystem;
      module = "keys";
      tools = [
        pkgs.openssl
        pkgs.openssh # ssh-keygen for the test CA
        pkgs.gnupg # the release key (release/index.key, .pgp)
      ];
      attrs = if variant == null then { } else { inherit variant; };
    };
}
