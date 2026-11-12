# Tests for the signer's key checks and signatures (lib/image/sign.nu, verity.nu, uki.nu,
# disk.nu). They call the functions the signer runs, on two key sets made here: a signature by
# the right key verifies with the public half the image carries, one by another key does not,
# and the signer refuses a key set that is not the half of the image's public keys. The whole
# signer runs in every test image (lib/image/signer.nix signedWithTestKeys).
#
# Keys on a PKCS#11 token: the db and PCR keys of set A, and the db key of set B, go onto a
# SoftHSM token (TEST-ONLY), and a key set names them by URI (secureboot/db.pkcs11,
# pcr/pcr.pkcs11). The same checks hold, and a signature from the token is the file key's, byte
# for byte.
#
# Run from the repo root with openssl, gpg, softhsm2-util on PATH, OPENSSL_MODULES naming
# pkcs11-provider's lib/ossl-modules and SOFTHSM_MODULE its libsofthsm2.so (checks.image-signer
# runs it so):
#   nu --no-config-file --include-path lib/image tests/sign/test.nu

use sign.nu [private-keys check-keys use-token]
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
fails "a PKCS#11 URI as a key set is refused: a key set is a directory" "secureboot/db.pkcs11" {||
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

# --- keys on a PKCS#11 token (SoftHSM, TEST-ONLY)
mkdir $"($tmp)/tokens"
$"directories.tokendir = ($tmp)/tokens\nobjectstore.backend = file\nlog.level = ERROR\n" | save -f $"($tmp)/softhsm2.conf"
$env.SOFTHSM2_CONF = $"($tmp)/softhsm2.conf"
^softhsm2-util --module $env.SOFTHSM_MODULE --init-token --free --label golconda-test --pin 1234 --so-pin 5678 | ignore
for k in [[file label id]; [$"($a)/secureboot/db.key" db-a "01"] [$"($a)/pcr/pcr.key" pcr-a "02"] [$"($b)/secureboot/db.key" db-b "03"]] {
  let r = (^softhsm2-util --module $env.SOFTHSM_MODULE --import $k.file --token golconda-test --label $k.label --id $k.id --pin 1234 | complete)
  if $r.exit_code != 0 { error make {msg: $"softhsm2-util --import ($k.label): ($r.stdout) ($r.stderr)"} }
}
def uri [label: string]: nothing -> string { $"pkcs11:token=golconda-test;object=($label);type=private?pin-value=1234" }

# a key set on the token: the public halves of A, the URIs in place of the db and PCR key files,
# the release key a file
def token-set [dir: string, db: string, pcr: string] {
  mkdir $"($dir)/secureboot" $"($dir)/pcr" $"($dir)/release"
  ^cp $"($a)/secureboot/db.crt" $"($dir)/secureboot/"
  ^cp $"($a)/pcr/pcr.pub" $"($dir)/pcr/"
  ^cp $"($a)/release/index.pgp" $"($a)/release/index.key" $"($dir)/release/"
  $"(uri $db)\n" | save -f $"($dir)/secureboot/db.pkcs11"
  $"(uri $pcr)\n" | save -f $"($dir)/pcr/pcr.pkcs11"
}
let ta = $"($tmp)/token-a"
token-set $ta db-a pcr-a
let priv_t = (private-keys $ta $ta $ta)
if $priv_t.dbKey != (uri db-a) or $priv_t.pcrKey != (uri pcr-a) {
  error make {msg: $"private-keys did not read the URIs: ($priv_t)"}
}
ok "a key set names its db and PCR keys on a token by URI"

fails "a key on a token needs a PKCS#11 module" "--pkcs11-module" {||
  use-token $priv_t $tmp
}
fails "a module that does not exist is refused" "no such PKCS#11 module" {||
  use-token $priv_t $tmp $"($tmp)/none.so"
}
use-token $priv_a $tmp
ok "keys in files need no module"
use-token $priv_t $tmp $env.SOFTHSM_MODULE

check-keys $priv_t (public-of $a)
ok "keys on the token pass against the public halves the image carries"
let tb = $"($tmp)/token-b"
token-set $tb db-b pcr-a
fails "a db key on the token that is not the certificate's is refused" "is not the key of the db certificate" {||
  check-keys (private-keys $tb $tb $tb) (public-of $a)
}
let tp = $"($tmp)/token-pcr"
token-set $tp db-a db-b
fails "a PCR key on the token that is not the image's is refused" "is not the key of the PCR public key" {||
  check-keys (private-keys $tp $tp $tp) (public-of $a)
}
# the db key on the token, the PCR key in a file (a rotation keeps the old set's)
check-keys (private-keys $ta $a $a) (public-of $a)
ok "the db key from a token and the PCR key from a file"

let both = $"($tmp)/both"
token-set $both db-a pcr-a
^cp $"($a)/secureboot/db.key" $"($both)/secureboot/"
fails "a key set with both a key file and a URI for one key is refused" "both" {||
  private-keys $both $both $both
}
let bad = $"($tmp)/bad-uri"
token-set $bad db-a pcr-a
"/srv/keys/db.key\n" | save -f $"($bad)/secureboot/db.pkcs11"
fails "a .pkcs11 file that holds no pkcs11: URI is refused" "not a pkcs11: URI" {||
  private-keys $bad $bad $bad
}
let rel_t = $"($tmp)/release-token"
token-set $rel_t db-a pcr-a
rm $"($rel_t)/release/index.key"
"pkcs11:token=golconda-test;object=index\n" | save -f $"($rel_t)/release/index.pkcs11"
fails "the release key cannot be a PKCS#11 URI: gpg signs the index" "release key" {||
  private-keys $rel_t $rel_t $rel_t
}

# the root hash signature from the token: verifies, and is the file key's bytes
let sig_t = (sign-roothash $roothash $priv_t.dbKey $"($a)/secureboot/db.crt")
if $sig_t != $sig_a {
  error make {msg: "the root hash signature from the token differs from the file key's"}
}
partition $"($tmp)/sig-t.raw" $roothash $sig_t
roothash-signature $"($tmp)/sig-t.raw" $roothash $"($a)/secureboot/db.crt" | ignore
ok "a root hash signed on the token verifies, and is the file key's signature byte for byte"
fails "a root hash signed with another key on the token does not verify" "does not verify against" {||
  partition $"($tmp)/sig-tb.raw" $roothash (sign-roothash $roothash (uri db-b) $"($b)/secureboot/db.crt")
  roothash-signature $"($tmp)/sig-tb.raw" $roothash $"($a)/secureboot/db.crt"
}

rm -rf $tmp
print "all signer tests passed"
