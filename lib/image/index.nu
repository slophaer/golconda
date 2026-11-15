# index.nu: the keyring for the signed update index (lib/image/index.nix indexKeyring).
#
# Copies the release key's public half to $out/import-pubring.pgp after checking that it is
# binary OpenPGP (systemd-pull hands it to gpg as --keyring), holds one public key, and no
# secret key: the file lands in /usr, which every release publishes.

use common.nu *

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  let raw = (open --raw $a.publicKey | into binary)
  if ($raw | bytes starts-with ("-----" | into binary)) {
    error make {msg: $"($a.publicKey) is ASCII armor; give the binary export \(gpg --export\)"}
  }
  let key = (pgp-keys $a.publicKey pub)
  mkdir $out
  ^cp $a.publicKey $"($out)/import-pubring.pgp"
  ^chmod 0444 $"($out)/import-pubring.pgp"
  log $"import-pubring.pgp: ($key.fpr)"
}
