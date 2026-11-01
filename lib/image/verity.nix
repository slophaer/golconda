# lib/image/verity.nix: the dm-verity hash tree of the /usr image and its signed root hash.
#
# verity { erofs; imageId; version; buildSystem; pkgs; key; cert; } → derivation with
#   <imageId>_<version>.usr-verity.raw      the hash tree (veritysetup format)
#   roothash                                 the root hash, hex, no newline
#   <imageId>_<version>.usr-verity-sig.raw  the usr-verity-sig partition: systemd's JSON
#                                            { rootHash, certificateFingerprint, signature },
#                                            NUL-padded to 4096 bytes (repart.c, dissect-image.c)
#
# The signature is the PKCS#7 of the hex root hash, as systemd-veritysetup documents it:
#   openssl smime -sign -nocerts -noattr -binary -in roothash -inkey key -signer cert -outform der
# Salt and superblock UUID derive from the version, so the root hash is reproducible.
#
# `key` and `cert` are paths: the db key pair signs the root hash (lib.mkImage in nix/default.nix
# takes the key directory, docs/design/trust.md); packages.image-smoke generates a throwaway pair.
_:
let
  common = import ./common.nix { };
in
{
  verity =
    {
      erofs,
      imageId,
      version,
      buildSystem,
      pkgs,
      key,
      cert,
      ... # platform and the rest of the shared argument set
    }:
    let
      stem = "${imageId}_${version}";
    in
    common.nuDerivation {
      name = "${stem}.usr-verity";
      inherit buildSystem;
      module = "verity";
      tools = [
        pkgs.cryptsetup
        pkgs.openssl
      ];
      attrs = {
        usrImage = "${erofs}/${stem}.usr.raw";
        hashFile = "${stem}.usr-verity.raw";
        sigFile = "${stem}.usr-verity-sig.raw";
        salt = common.hexOf "${stem}.usr-verity.raw";
        uuid = common.uuidOfHex (common.hexOf "${stem}.usr-verity.raw");
        inherit key cert;
      };
    };
}
