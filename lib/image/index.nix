# lib/image/index.nix: the keyring the image checks the signed update index with.
#
# indexKeyring { buildSystem; pkgs; publicKey; } → derivation with import-pubring.pgp: the
#   release key's public half (the key set's release/index.pgp), checked to be one binary
#   OpenPGP public key and no secret, under the name systemd-pull reads.
# indexFragment { keyring; pkgs; } → a /system fragment that links the keyring to
#   /usr/lib/systemd/import-pubring.pgp (systemd's vendor keyring path) and puts gnupg in /usr:
#   systemd-pull runs `gpg --verify` on SHA256SUMS.gpg for every transfer with Verify=yes
#   (image/sysupdate.nix). Give it to mkSystem through extraFragments.
#
# The signer (lib/image/disk.nu sign-index) signs the release's SHA256SUMS with the secret half.
_:
let
  common = import ./common.nix { };
  usrPath = "/usr/lib/systemd/import-pubring.pgp";
in
{
  indexKeyringUsrPath = usrPath;

  indexKeyring =
    {
      buildSystem,
      pkgs,
      publicKey,
    }:
    common.nuDerivation {
      name = "golconda-index-keyring";
      inherit buildSystem;
      module = "index";
      tools = [ pkgs.gnupg ];
      attrs = {
        inherit publicKey;
      };
    };

  indexFragment =
    { keyring, pkgs }:
    {
      name = "/image/index";
      packages = [
        keyring
        pkgs.gnupg
      ];
      links.${usrPath} = {
        target = "${keyring}/import-pubring.pgp";
        kind = "explicit";
      };
    };
}
