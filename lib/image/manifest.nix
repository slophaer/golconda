# lib/image/manifest.nix: the unsigned outputs of the image chain, what the signer takes.
#
# manifest { imageId; version; platform; buildSystem; pkgs; usrTree; initrd; signer; publicKeys;
#   secureBoot; microsoftKeys; }
#   → derivation with
#   manifest.json   every input of the signer (lib/image/sign.nu): the /usr tree, the initrd, the
#                   kernel, systemd's stub and unsigned systemd-boot (store paths, so they are
#                   this output's closure), and the parameters of each step from the version:
#                   erofs (erofs.nix), verity (verity.nix), uki (uki.nix), loader (loader.nix),
#                   disk with the repart definitions (disk.nix), the release file names
#                   (releaseNames), and publicKeys
#   keys/           db.crt, pcr.pub, index.pgp: copies of the public halves of the keys the image
#                   trusts (publicKeys: { dbCert; pcrPublicKey; indexKeyring; }). The build fails
#                   on a file that holds a private key
#   sign            the signer of this image's package set (signer.nix): sign -> bin/golconda-sign
#
# Nothing here is signed, and no private key is an input: the output path does not change with
# the private keys, only with their public halves (the /usr tree holds the release keyring, the
# kernel of an image without Secure Boot the db certificate).
_:
let
  common = import ./common.nix { };
  erofs = import ./erofs.nix { };
  verity = import ./verity.nix { };
  uki = import ./uki.nix { };
  loader = import ./loader.nix { };
  disk = import ./disk.nix { };
in
{
  manifest =
    args@{
      imageId,
      version,
      platform,
      buildSystem,
      pkgs,
      usrTree,
      signer,
      publicKeys,
      secureBoot,
      microsoftKeys,
      ...
    }:
    common.nuDerivation {
      name = "${imageId}_${version}.unsigned";
      inherit buildSystem;
      module = "manifest";
      tools = [
        pkgs.openssl
        pkgs.gnupg
      ];
      attrs = {
        signer = "${signer}";
        manifest = {
          inherit imageId version;
          # a derivation: the JSON gets its path, Nix code its attributes (tests/real-packages)
          inherit usrTree;
          loader = loader.loaderParams {
            inherit
              platform
              pkgs
              secureBoot
              microsoftKeys
              ;
          };
          erofs = erofs.erofsParams { inherit imageId version; };
          verity = verity.verityParams { inherit imageId version; };
          uki = uki.ukiParams args;
          disk = disk.diskParams { inherit imageId version platform; };
          release = disk.releaseNames { inherit imageId version; };
          publicKeys = {
            dbCert = "${publicKeys.dbCert}";
            pcrPublicKey = "${publicKeys.pcrPublicKey}";
            indexKeyring = "${publicKeys.indexKeyring}";
          };
        };
      };
    };
}
