# Tests for the signer's key checks and signatures (lib/image/sign.nu, verity.nu, uki.nu,
# disk.nu). They call the functions the signer runs, on two key sets made here: a signature by
# the right key verifies with the public half the image carries, one by another key does not,
# and the signer refuses a key set that is not the half of the image's public keys. The whole
# signer runs in every test image (lib/image/signer.nix signedWithTestKeys).
#
# Run from the repo root with openssl and gpg on PATH (checks.image-signer runs it so):
#   nu --no-config-file --include-path lib/image tests/sign/test.nu

use sign.nu [private-keys check-keys]
use verity.nu [sign-roothash]
use uki.nu [roothash-signature]
use disk.nu [sign-index verify-index]

$env.OPENSSL_CONF = "/dev/null"
let tmp = (mktemp -d -t "golconda-sign-test-XXXXXX")

# a key set in scripts/make-keys' layout
def key-set [dir: string, name: string] {
  mkdir $"($dir)/secureboot" $"($dir)/pcr" $"($dir)/release"
  ^openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj $"/CN=($name) db/" -keyout $"($dir)/secureboot/db.key" -out $"($dir)/secureboot/db.crt" e> /dev/null
  ^openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out $"($dir)/pcr/pcr.key" e> /dev/null
  ^openssl pkey -in $"($dir)/pcr/pcr.key" -pubout -out $"($dir)/pcr/pcr.pub"
  let home = $"($dir)/gnupg"
  mkdir $home
  ^chmod 700 $home
  with-env {GNUPGHOME: $home} {
    ^gpg --batch --passphrase '' --quick-gen-key $"($name) <index@golconda.invalid>" ed25519 sign never e> /dev/null
    ^gpg --batch --export --output $"($dir)/release/index.pgp"
    ^gpg --batch --pinentry-mode loopback --passphrase '' --armor --export-secret-keys --output $"($dir)/release/index.key"
    ^gpgconf --kill gpg-agent
  }
  rm -rf $home
}

# what the manifest names: the public halves
def public-of [dir: string]: nothing -> record {
  {dbCert: $"($dir)/secureboot/db.crt" pcrPublicKey: $"($dir)/pcr/pcr.pub" indexKeyring: $"($dir)/release/index.pgp"}
}

def ok [name: string] { print $"ok: ($name)" }

# BODY must fail with a message that contains WANT
def fails [name: string, want: string, body: closure] {
  let msg = (try { do $body; "no error" } catch {|e| $e.msg })
  if not ($msg | str contains $want) {
    error make {msg: $"($name): expected an error with '($want)', got '($msg)'"}
  }
  ok $name
}

let a = $"($tmp)/a"
let b = $"($tmp)/b"
key-set $a "Test A"
key-set $b "Test B"

# --- the key checks
let priv_a = (private-keys $a $a $a)
check-keys $priv_a (public-of $a)
ok "a key set passes against its own public halves"

fails "another db key is refused" "is not the key of the db certificate" {||
  check-keys (private-keys $b $a $a) (public-of $a)
}
fails "another PCR key is refused" "is not the key of the PCR public key" {||
  check-keys (private-keys $a $b $a) (public-of $a)
}
fails "another release key is refused" "but this image trusts" {||
  check-keys (private-keys $a $a $b) (public-of $a)
}
# a db rotation: the new db key with the PCR and release keys of the first set
check-keys (private-keys $b $a $a) {dbCert: $"($b)/secureboot/db.crt" pcrPublicKey: $"($a)/pcr/pcr.pub" indexKeyring: $"($a)/release/index.pgp"}
ok "a rotation takes the db key of one set and the PCR and release keys of another"
fails "a PKCS#11 URI is refused, not yet supported" "PKCS#11" {||
  private-keys "pkcs11:token=golconda" $a $a
}
fails "a key set without its key file is refused" "no such key" {||
  private-keys $"($tmp)/none" $a $a
}

# --- the verity root hash signature: PKCS#7 by the db key, checked against the certificate
let roothash = "4b1a9e3cbd7f0e6d2c5a8f9e1d3b7c6a5f4e3d2c1b0a99887766554433221100"
def partition [file: string, roothash: string, sig: string] {
  {rootHash: $roothash certificateFingerprint: "" signature: $sig} | to json -r | save -f $file
}
let sig_a = (sign-roothash $roothash $priv_a.dbKey $"($a)/secureboot/db.crt")
partition $"($tmp)/sig-a.raw" $roothash $sig_a
let got = (roothash-signature $"($tmp)/sig-a.raw" $roothash $"($a)/secureboot/db.crt")
if $got != $sig_a { error make {msg: "roothash-signature returned another signature"} }
ok "a root hash signed with the db key verifies against its certificate"
if (sign-roothash $roothash $priv_a.dbKey $"($a)/secureboot/db.crt") != $sig_a {
  error make {msg: "a second root hash signature differs: not deterministic"}
}
ok "the root hash signature is deterministic"
fails "a root hash signature by another key does not verify" "does not verify against" {||
  roothash-signature $"($tmp)/sig-a.raw" $roothash $"($b)/secureboot/db.crt"
}
partition $"($tmp)/sig-other.raw" ($roothash | str replace "4b1a" "4b1b") $sig_a
fails "a signature of another root hash is refused" "signs" {||
  roothash-signature $"($tmp)/sig-other.raw" $roothash $"($a)/secureboot/db.crt"
}

# --- the release index: SHA256SUMS.gpg by the release key, checked with gpgv against the keyring
let rel = $"($tmp)/release"
mkdir $rel
"0000  some_20261031.1.efi\n" | save -f $"($rel)/SHA256SUMS"
sign-index $rel $priv_a.indexKey 1793404801 $"($a)/release/index.pgp"
let first = (open --raw $"($rel)/SHA256SUMS.gpg" | hash sha256)
ok "SHA256SUMS signed with the release key verifies against its keyring"
rm $"($rel)/SHA256SUMS.gpg"
sign-index $rel $priv_a.indexKey 1793404801 $"($a)/release/index.pgp"
if (open --raw $"($rel)/SHA256SUMS.gpg" | hash sha256) != $first {
  error make {msg: "a second SHA256SUMS.gpg differs: not deterministic"}
}
ok "the index signature is deterministic"
fails "the index signature does not verify against another keyring" "does not verify" {||
  verify-index $rel $"($b)/release/index.pgp"
}
fails "signing with a key the keyring does not hold fails" "does not verify" {||
  sign-index $rel $"($b)/release/index.key" 1793404801 $"($a)/release/index.pgp"
}
"0001  some_20261031.1.efi\n" | save -f $"($rel)/SHA256SUMS"
fails "a changed index does not verify" "does not verify" {||
  verify-index $rel $"($a)/release/index.pgp"
}

rm -rf $tmp
print "all signer tests passed"
