# keys.nu: throwaway key pairs for the smoke (lib/image/default.nix throwawayKeys).
#
# Output: secureboot/db.{key,crt} (it signs the UKI, the verity root hash and the loader),
# pcr/pcr.key with pcr/pcr.pub (the public key ukify embeds as .pcrpkey), and
# release/index.key with release/index.pgp: the OpenPGP key that signs the release's SHA256SUMS
# (armored secret key; binary public key, the image's keyring).

use common.nu *

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  # repkgs' openssl reads /etc/ssl/openssl.cnf (OPENSSLDIR); there is none in the sandbox
  $env.OPENSSL_CONF = "/dev/null"
  # a variant (lib/image/default.nix throwawayKeys) is named in the CN, so the certificates
  # tell the sets apart in the firmware's db and the kernel's keyrings
  let suffix = (if ($a.variant? | default null) == null { "" } else { $" ($a.variant)" })
  for pair in [[dir name cn]; [secureboot db $"Golconda smoke Secure Boot db($suffix)"]] {
    mkdir $"($out)/($pair.dir)"
    ^openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj $"/CN=($pair.cn)/" -keyout $"($out)/($pair.dir)/($pair.name).key" -out $"($out)/($pair.dir)/($pair.name).crt" e> /dev/null
    log $"($pair.dir)/($pair.name).key, .crt"
  }
  mkdir $"($out)/pcr"
  ^openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out $"($out)/pcr/pcr.key" e> /dev/null
  ^openssl pkey -in $"($out)/pcr/pcr.key" -pubout -out $"($out)/pcr/pcr.pub"
  log "pcr/pcr.key, .pub"
  index-key $"($out)/release" $"Golconda smoke release index($suffix)"
}

# An Ed25519 OpenPGP signing key without a passphrase, made in a scratch home that is removed
# with its agent: release/index.key (armored secret) and release/index.pgp (binary public)
def index-key [dir: string, name: string] {
  mkdir $dir
  let home = $"($env.TMPDIR? | default /tmp)/gnupg-keys"
  mkdir $home
  ^chmod 700 $home
  with-env {GNUPGHOME: $home} {
    ^gpg --batch --passphrase '' --quick-gen-key $"($name) <index@golconda.invalid>" ed25519 sign never e> /dev/null
    ^gpg --batch --export --output $"($dir)/index.pgp"
    ^gpg --batch --pinentry-mode loopback --passphrase '' --armor --export-secret-keys --output $"($dir)/index.key"
    ^gpgconf --kill gpg-agent
  }
  rm -rf $home
  log "release/index.key, .pgp"
}
