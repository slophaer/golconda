# lib/image/verity.nix: how the signer makes the dm-verity hash tree and the signed root hash.
#
# verityParams { imageId; version; } → the manifest's `verity` (lib/image/manifest.nix):
#   hashFile   <imageId>_<version>.usr-verity.raw      the hash tree (veritysetup format)
#   sigFile    <imageId>_<version>.usr-verity-sig.raw  the usr-verity-sig partition: systemd's
#              JSON { rootHash, certificateFingerprint, signature }, NUL-padded to 4096 bytes
#   salt, uuid from the version, so the root hash is reproducible
#
# The signer (lib/image/verity.nu) signs the hex root hash with the db key, as
# systemd-veritysetup documents it:
#   openssl smime -sign -nocerts -noattr -binary -in roothash -inkey key -signer cert -outform der
_:
let
  common = import ./common.nix { };
in
{
  verityParams =
    { imageId, version }:
    let
      stem = "${imageId}_${version}";
    in
    {
      hashFile = "${stem}.usr-verity.raw";
      sigFile = "${stem}.usr-verity-sig.raw";
      salt = common.hexOf "${stem}.usr-verity.raw";
      uuid = common.uuidOfHex (common.hexOf "${stem}.usr-verity.raw");
    };
}
