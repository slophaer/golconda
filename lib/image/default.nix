# lib/image: from a /usr tree to a bootable disk image, with repkgs packages only.
#
# Nix builds the unsigned parts; the signer signs and assembles the release outside the store
# (docs/design/trust.md, "Signing outside Nix"):
#   initrd    a minimal /usr tree as a zstd cpio, systemd as PID 1           (initrd.nix)
#   index     the release key's public half, the keyring of the signed index (index.nix)
#   manifest  the unsigned outputs: manifest.json, the public halves, the signer (manifest.nix)
#   signer    golconda-sign (signer.nix, sign.nu): the loader, mkfs.erofs, verity and its
#             signature, the UKI with .pcrsig, the disk (systemd-repart), the release directory
#             and SHA256SUMS.gpg; the steps are erofs.nu, verity.nu, loader.nu, uki.nu, disk.nu,
#             their parameters erofs.nix, verity.nix, loader.nix, uki.nix, disk.nix
#   signedWithTestKeys  the same signer in a derivation, with throwaway keys (signer.nix)
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
// (import ./manifest.nix { })
// (import ./signer.nix { })
// (import ./smoke.nix { })
// {
  inherit (common) versionToEpoch uuidOfHex hexOf;

  # throwawayKeys { buildSystem; pkgs; variant ? null; reusePkKek ? null; } → derivation with the
  # key pairs for
  # the test images: the Secure Boot db (it also signs the verity root hash and the loader), the
  # PCR policy key, made with openssl, and the release key, made with gpg. All made inside the
  # store: they are test fixtures, and a production key never enters the store. Output `out` is
  # the whole set (signedWithTestKeys reads it); output `public` the public halves alone (the
  # chain's publicKeys, and the boot test's --keys). A `variant` is a second, different set (its
  # name and the certificates' CN carry it): the key rotation test signs the next release with
  # it (docs/design/bootloader.md); `reusePkKek`, another throwaway set, gives the variant that
  # set's PK and KEK, as `scripts/make-keys --reuse-pk-kek` does. The set has the enrolment files
  # (secureboot/auth, lib/image/enrol.nu) with Microsoft's objects (packages/secureboot-objects).
  # Its builder sees keys.nu, enrol.nu and common.nu only, so an edit of another step keeps the
  # keys, and with them every unsigned output.
  throwawayKeys =
    {
      buildSystem,
      pkgs,
      variant ? null,
      reusePkKek ? null,
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
      modules = [
        "keys.nu"
        "enrol.nu"
        "common.nu"
      ];
      attrs = {
        outputs = [
          "out"
          "public"
        ];
        secureBootObjects = "${pkgs.secureboot-objects}/share/secureboot-objects";
      }
      // (if variant == null then { } else { inherit variant; })
      // (if reusePkKek == null then { } else { reusePkKek = "${reusePkKek}"; });
    };
}
