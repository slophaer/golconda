# manifest.nu: the unsigned outputs of the image chain (lib/image/manifest.nix): manifest.json,
# the public halves of the keys the image trusts, and `sign`, the signer.
#
# Structured attrs: manifest (the record manifest.json holds, with publicKeys as the paths of the
# key set's public files), signer.

use common.nu *

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  $env.OPENSSL_CONF = "/dev/null" # no /etc/ssl/openssl.cnf in the sandbox
  mkdir $"($out)/keys"
  let p = $a.manifest.publicKeys

  # copies: the manifest names them, so the output's closure holds no other file of the key set
  for f in [[name from]; [db.crt $p.dbCert] [pcr.pub $p.pcrPublicKey] [index.pgp $p.indexKeyring]] {
    let raw = (open --raw $f.from | into binary)
    # PEM and armored OpenPGP secrets alike ("-----BEGIN PGP PRIVATE KEY BLOCK"); gpg below
    # refuses a binary secret key
    if ($raw | bytes index-of ("PRIVATE KEY" | into binary)) >= 0 {
      error make {msg: $"($f.from): holds a private key; give only the public half"}
    }
    ^cp $f.from $"($out)/keys/($f.name)"
  }
  ^openssl x509 -in $"($out)/keys/db.crt" -noout
  ^openssl pkey -pubin -in $"($out)/keys/pcr.pub" -noout
  $env.GNUPGHOME = (mktemp -d -t "golconda-gnupg-XXXXXX")
  let rows = (^gpg --batch --with-colons --show-keys $"($out)/keys/index.pgp" | lines)
  if ($rows | where {|l| $l starts-with "sec:" } | length) != 0 or ($rows | where {|l| $l starts-with "pub:" } | length) != 1 {
    error make {msg: $"($p.indexKeyring): expected one public OpenPGP key and no secret key"}
  }

  $a.manifest
    | upsert publicKeys {dbCert: $"($out)/keys/db.crt" pcrPublicKey: $"($out)/keys/pcr.pub" indexKeyring: $"($out)/keys/index.pgp"}
    | to json
    | save -f $"($out)/manifest.json"
  ^ln -s $"($a.signer)/bin/golconda-sign" $"($out)/sign"
  log $"manifest.json: ($a.manifest.imageId) ($a.manifest.version)"
}
