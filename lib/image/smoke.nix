# lib/image/smoke.nix: the whole chain in one output, with its proofs.
#
# smoke { erofs; verity; initrd; uki; disk; keys; imageId; version; buildSystem; pkgs; } →
#   derivation: a symlink to each step's output (usr, verity, initrd, uki, disk, keys) and
#   proof.txt, what the tools say about them: veritysetup verify, the first cpio entries, ukify
#   inspect, the sizes, and repart's listing of the disk. The keys/ symlink points at the
#   throwaway keys (secureboot/db.crt, pcr/pcr.pub) so scripts/boot-test can
#   enrol them into OVMF vars. packages.image-smoke in nix/default.nix wires it.
_:
let
  common = import ./common.nix { };
in
{
  smoke =
    {
      erofs,
      verity,
      initrd,
      uki,
      disk,
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
        inherit
          erofs
          verity
          initrd
          uki
          disk
          keys
          ;
        stem = "${imageId}_${version}";
      };
    };
}
