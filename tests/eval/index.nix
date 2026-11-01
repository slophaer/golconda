# Checks of the signed sysupdate index: Verify=yes, the keyring at systemd's vendor path, gpg in /usr.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  fixturePkgs,
  imageLib,
  ...
}:
# The signed index: every transfer verifies SHA256SUMS.gpg (Verify=yes), against the keyring
# the image carries at systemd's vendor path, and the image carries gpg, which systemd-pull
# runs. The disk step signs the index with the release key (docs/design/releases.md).
let
  inherit (builtins)
    all
    any
    attrNames
    elem
    ;
  transfers = (import ../../image).sysupdate {
    imageId = "x";
    updateSource = "https://u.example/";
  };
  keyring = derivation {
    name = "keyring-stand-in";
    system = "x";
    builder = "x";
  };
  frag = imageLib.indexFragment {
    inherit keyring;
    pkgs = fixturePkgs;
  };
in
[
  (check "index: every transfer verifies the signed index" (
    all (n: transfers.${n}.Transfer.Verify == true) (attrNames transfers)
  ))
  (check "index: the keyring is at systemd's vendor path, and gpg is in /usr" (
    frag.links."/usr/lib/systemd/import-pubring.pgp".target == "${keyring}/import-pubring.pgp"
    && any (p: (p.pname or "") == "gnupg") frag.packages
    && elem keyring frag.packages
  ))
]
