# keys.nu: throwaway key pairs for the test images (lib/image/default.nix throwawayKeys), in the
# layout of scripts/make-keys (docs/reference/release.md), with the enrolment files of lib/image/enrol.nu.
#
# A set with `reusePkKek` (another set's `out`) is a db rotation: it takes that set's PK.crt and
# KEK.crt, has no PK or KEK key, and its .auth files are signed by that set's keys.
#
# Output `public` holds the public halves alone, so the closure of the unsigned chain has no
# private key (lib/image/chain.nix publicKeys). The boot test reads its PK.crt and KEK.crt
# (--auto-enrol); the signer reads `out`.

use common.nu *
use enrol.nu

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  # no configuration: the certificates carry only the extensions named here (openssl.cnf's [req]
  # would add its v3_ca ones)
  $env.OPENSSL_CONF = "/dev/null"
  # a variant (lib/image/default.nix throwawayKeys) is named in the CN, so the certificates
  # tell the sets apart in the firmware's db and the kernel's keyrings
  let suffix = (if ($a.variant? | default null) == null { "" } else { $" ($a.variant)" })
  let reuse = ($a.reusePkKek? | default null)
  let own = (if $reuse == null { [db PK KEK] } else { [db] })
  mkdir $"($out)/secureboot"
  for k in $own {
    ^openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj $"/CN=Golconda smoke Secure Boot ($k)($suffix)/" -keyout $"($out)/secureboot/($k).key" -out $"($out)/secureboot/($k).crt" e> /dev/null
    log $"secureboot/($k).key, .crt"
  }
  let signing = (if $reuse == null { $"($out)/secureboot" } else { $"($reuse)/secureboot" })
  if $reuse != null {
    for k in [PK KEK] { ^cp $"($reuse)/secureboot/($k).crt" $"($out)/secureboot/($k).crt" }
    log $"secureboot/PK.crt, KEK.crt: ($reuse)'s"
  }
  let sb = $"($out)/secureboot"
  (enrol write $"($sb)/auth"
    {pk: $"($sb)/PK.crt" kek: $"($sb)/KEK.crt" db: $"($sb)/db.crt"}
    {pkKey: $"($signing)/PK.key" pkCert: $"($signing)/PK.crt" kekKey: $"($signing)/KEK.key" kekCert: $"($signing)/KEK.crt"}
    $a.secureBootObjects 1793404801)
  mkdir $"($out)/pcr"
  ^openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out $"($out)/pcr/pcr.key" e> /dev/null
  ^openssl pkey -in $"($out)/pcr/pcr.key" -pubout -out $"($out)/pcr/pcr.pub"
  log "pcr/pcr.key, .pub"
  index-key $"($out)/release" $"Golconda smoke release index($suffix)"
  let public = $a.outputs.public
  for f in [secureboot/db.crt secureboot/PK.crt secureboot/KEK.crt secureboot/auth pcr/pcr.pub release/index.pgp] {
    mkdir ($"($public)/($f)" | path dirname)
    ^cp -R $"($out)/($f)" $"($public)/($f)"
  }
  log "public: secureboot/db.crt, PK.crt, KEK.crt, auth/, pcr/pcr.pub, release/index.pgp"
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
