# lib/image/erofs.nix: the /usr tree as an erofs image.
#
# erofs { usrTree; imageId; version; buildSystem; pkgs; } → derivation with
#   <imageId>_<version>.usr.raw
#
# mkfs.erofs -T <epoch> with the epoch from the version (common.nix versionToEpoch), so every
# file and the filesystem itself carry the version's timestamp: ConditionNeedsUpdate= fires once
# per version (image/erofs.nix). --all-root: the sandbox's user is nobody's. -U fixes the
# filesystem UUID from the version too, the only other value mkfs.erofs would draw at random.
# The result is reproducible: the derivation is content-addressed, so a second build of the
# same tree lands on the same store path (proven in packages.image-smoke).
_:
let
  common = import ./common.nix { };
  erofsConfig = import ../../image/erofs.nix;
in
{
  erofs =
    {
      usrTree,
      imageId,
      version,
      buildSystem,
      pkgs,
      ... # platform and the rest of the shared argument set
    }:
    common.nuDerivation {
      name = "${imageId}_${version}.usr.raw";
      inherit buildSystem;
      module = "erofs";
      tools = [ pkgs.erofs-utils ];
      attrs = {
        inherit usrTree;
        epoch = common.versionToEpoch version;
        fileName = "${imageId}_${version}.usr.raw";
        uuid = common.uuidOfHex (common.hexOf "${imageId}_${version}.usr.raw");
        inherit (erofsConfig) compression extraArgs;
      };
    };
}
