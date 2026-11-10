# lib/image/smoke.nix: a test image in one output, with its proofs.
#
# smoke { unsigned; signed; keys; imageId; version; buildSystem; pkgs; } → derivation: a symlink
#   to the unsigned outputs (`unsigned`, lib/image/manifest.nix), to the signed release (`disk`:
#   disk.raw and release/, signedWithTestKeys) and to the public halves of the throwaway keys
#   (`keys`: secureboot/db.crt and release/index.pgp, which scripts/boot-test enrols and
#   compares), and proof.txt, what the tools say about them: veritysetup verify, the first cpio
#   entries, ukify inspect, the sizes, and repart's listing of the disk. The test images in
#   nix/default.nix wire it.
_:
let
  common = import ./common.nix { };
in
{
  smoke =
    {
      unsigned,
      signed,
      keys,
      imageId,
      version,
      buildSystem,
      pkgs,
      ... # platform and the rest of the shared argument set
    }:
    common.nuDerivation {
      name = "${imageId}_${version}.image-smoke";
      inherit buildSystem;
      module = "smoke";
      tools = [
        pkgs.cryptsetup
        pkgs.ukify
        pkgs.systemd
      ];
      libs = [
        pkgs.openssl
        pkgs.tpm2-tss
      ];
      attrs = {
        inherit unsigned signed keys;
      };
    };
}
