# lib/image/erofs.nix: how the signer makes the /usr tree into an erofs image.
#
# erofsParams { imageId; version; } → the manifest's `erofs` (lib/image/manifest.nix):
#   fileName     <imageId>_<version>.usr.raw
#   epoch        mkfs.erofs -T, from the version (lib/version.nix): every file and the
#                filesystem itself carry the version's timestamp, so ConditionNeedsUpdate= fires
#                once per version
#   uuid         -U, from the version too, the only other value mkfs.erofs would draw at random
#   compression  -z: lz4hc
#
# The signer (lib/image/erofs.nu) runs mkfs.erofs, not Nix: /usr carries the signed loader
# (lib/image/sign.nu), so the image's bytes depend on a signature (docs/design/trust.md).
_:
let
  common = import ./common.nix { };
in
{
  erofsParams =
    { imageId, version }:
    {
      fileName = "${imageId}_${version}.usr.raw";
      epoch = (import ../version.nix { }).toEpoch version;
      uuid = common.uuidOfHex (common.hexOf "${imageId}_${version}.usr.raw");
      compression = "lz4hc";
    };
}
