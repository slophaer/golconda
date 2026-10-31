# verity.nu: veritysetup format + the signed root hash (lib/image/verity.nix).
#
# Structured attrs: usrImage, hashFile, sigFile, salt, uuid, key, cert.

use common.nu *

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  $env.OPENSSL_CONF = "/dev/null" # no /etc/ssl/openssl.cnf in the sandbox
  mkdir $out
  let hash = $"($out)/($a.hashFile)"

  log $"veritysetup format ($a.usrImage)"
  ^veritysetup format --salt $a.salt --uuid $a.uuid --root-hash-file $"($out)/roothash" $a.usrImage $hash
  let roothash = (open --raw $"($out)/roothash" | str trim)
  # the file ends without a newline: what systemd hashes and what the cmdline carries
  $roothash | save -f $"($out)/roothash"
  log $"root hash ($roothash)"

  ^veritysetup verify $a.usrImage $hash $roothash
  log "veritysetup verify: ok"

  # PROTOTYPE (no initrd): what dm-mod.create= needs besides the root hash. The hash device
  # starts with veritysetup's superblock, so the tree starts at hash block 1.
  let dump = (^veritysetup dump $hash | lines | parse -r '^(?P<k>[^:]+):\s+(?P<v>.*)$' | transpose -r -d)
  {dataBlocks: ($dump."Data blocks" | into int), dataBlockSize: ($dump."Data block size" | split row " " | first | into int), hashBlockSize: ($dump."Hash block size" | split row " " | first | into int), hashStart: 1, algorithm: $dump."Hash algorithm", salt: $dump.Salt}
    | to json -r | save -f $"($out)/table.json"

  # PKCS#7 of the hex root hash (systemd-veritysetup(8)), DER
  let der = $"($env.NIX_BUILD_TOP)/roothash.p7s"
  ^openssl smime -sign -nocerts -noattr -binary -in $"($out)/roothash" -inkey $a.key -signer $a.cert -outform der -out $der
  let fingerprint = (^openssl x509 -in $a.cert -outform der | ^sha256sum | split row " " | first)
  let signature = (open --raw $der | encode base64)
  {rootHash: $roothash, certificateFingerprint: $fingerprint, signature: $signature}
    | to json -r | save -f $"($out)/($a.sigFile)"
  pad-to $"($out)/($a.sigFile)" 4096
  log $"($a.sigFile): (ls $"($out)/($a.sigFile)" | get size.0)"
}
