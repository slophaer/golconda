# lib/image: from a /usr tree to a bootable disk image, with repkgs packages only. Nix builds the
# unsigned parts (initrd, index, manifest, the signer); the signer signs and assembles the release
# outside the store (docs/design/trust.md, "Signing outside Nix"). The artifacts:
# docs/reference/image.md; why: docs/design/{layout,boot,trust}.md.
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

  # throwawayKeys { buildSystem; pkgs; variant ? null; reusePkKek ? null; } -> derivation with the
  # key pairs of the test images: the Secure Boot db, the PCR policy key and the release key. They
  # are made inside the store because they are fixtures: a production key never enters it. `out` is
  # the whole set, `public` the public halves (the chain's publicKeys, the boot test's --keys). A
  # `variant` is a second set for the key rotation test (docs/design/bootloader.md); `reusePkKek`
  # gives it that set's PK and KEK. The builder sees keys.nu, enrol.nu and common.nu only, so an
  # edit of another step keeps the keys and every unsigned output.
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
        pkgs.efitools # the enrolment files (enrol.nu)
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
