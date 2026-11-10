# verity.nu: veritysetup format and the signed root hash, a step of the signer
# (lib/image/sign.nu). The parameters come from the manifest's `verity` (lib/image/verity.nix).

use common.nu *

# make USR DIR PARAMS KEY CERT: the hash tree DIR/<hashFile> and the usr-verity-sig partition
# DIR/<sigFile> of the erofs image USR; returns the root hash. The signature is the PKCS#7 of
# the hex root hash (systemd-veritysetup(8)) by KEY, which must be the half of CERT; the
# partition is systemd's JSON { rootHash, certificateFingerprint, signature }, NUL-padded to
# 4096 bytes (repart.c, dissect-image.c).
export def make [usr: string, dir: string, p: record, key: string, cert: string]: nothing -> string {
  let hash = $"($dir)/($p.hashFile)"
  let work = (mktemp -d -t "golconda-verity-XXXXXX")
  log $"veritysetup format ($usr | path basename)"
  ^veritysetup format --salt $p.salt --uuid $p.uuid --root-hash-file $"($work)/roothash" $usr $hash | ignore
  let roothash = (open --raw $"($work)/roothash" | str trim)
  # without a newline: what systemd hashes and what the cmdline carries
  $roothash | save -f $"($work)/roothash"
  log $"root hash ($roothash)"
  ^veritysetup verify $usr $hash $roothash
  log "veritysetup verify: ok"

  let sig = (sign-roothash $roothash $key $cert)
  let fingerprint = (^openssl x509 -in $cert -outform der | ^sha256sum | split row " " | first)
  {rootHash: $roothash, certificateFingerprint: $fingerprint, signature: $sig}
    | to json -r | save -f $"($dir)/($p.sigFile)"
  pad-to $"($dir)/($p.sigFile)" 4096
  rm -rf $work
  log $"($p.sigFile): (ls $"($dir)/($p.sigFile)" | get size.0)"
  $roothash
}

# sign-roothash ROOTHASH KEY CERT: the base64 DER PKCS#7 of the hex string, without certificates
# or attributes, as the kernel's dm-verity takes it
export def sign-roothash [roothash: string, key: string, cert: string]: nothing -> string {
  let work = (mktemp -d -t "golconda-roothash-XXXXXX")
  $roothash | save -f $"($work)/roothash"
  ^openssl smime -sign -nocerts -noattr -binary -in $"($work)/roothash" -inkey $key -signer $cert -outform der -out $"($work)/roothash.p7s"
  let sig = (open --raw $"($work)/roothash.p7s" | encode base64)
  rm -rf $work
  $sig
}
