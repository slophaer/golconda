# token.nu: a test image's release signed from a PKCS#11 token (lib/image/signer.nix
# signedWithTestToken). A SoftHSM token (TEST-ONLY) in the build's own directory gets the
# throwaway db and PCR keys; a key set names them by URI (secureboot/db.pkcs11, pcr/pcr.pkcs11),
# and the signer a release host runs, `unsigned`'s sign, signs with them through pkcs11-provider.
# The release key stays a file (sign.nu private-keys). The keys enter the store as the
# throwaway keys do: test fixtures only.

use common.nu *

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  $env.OPENSSL_CONF = "/dev/null"
  let t = $"($env.TMPDIR? | default /tmp)/token"
  mkdir $"($t)/tokens"
  $"directories.tokendir = ($t)/tokens\nobjectstore.backend = file\nlog.level = ERROR\n" | save -f $"($t)/softhsm2.conf"
  # the signer's wrapper passes SOFTHSM2_CONF on (lib/image/signer.nu)
  $env.SOFTHSM2_CONF = $"($t)/softhsm2.conf"
  let module = $a.pkcs11Module
  ^softhsm2-util --module $module --init-token --free --label golconda-test --pin 1234 --so-pin 5678
  let set = $"($t)/keys"
  for k in [[dir base keys id]; [secureboot db $a.keys "01"] [pcr pcr $a.pcrKeys "02"]] {
    ^softhsm2-util --module $module --import $"($k.keys)/($k.dir)/($k.base).key" --token golconda-test --label $k.base --id $k.id --pin 1234
    mkdir $"($set)/($k.dir)"
    $"pkcs11:token=golconda-test;object=($k.base);type=private?pin-value=1234\n" | save -f $"($set)/($k.dir)/($k.base).pkcs11"
  }
  # the public halves, as in a deployment's set (the signer reads them from the manifest)
  ^cp $"($a.keys)/secureboot/db.crt" $"($set)/secureboot/"
  # and the Secure Boot enrolment files with their PK and KEK certificates, which make-keys wrote
  # once: the set has no PK or KEK key, as a deployment's need not
  ^cp -R $"($a.keys)/secureboot/PK.crt" $"($a.keys)/secureboot/KEK.crt" $"($a.keys)/secureboot/auth" $"($set)/secureboot/"
  ^cp $"($a.pcrKeys)/pcr/pcr.pub" $"($set)/pcr/"
  log "token golconda-test: db, pcr"
  ^$"($a.unsigned)/sign" $a.unsigned --keys $set --pcr-keys $set --index-keys $a.indexKeys --pkcs11-module $module --out $out
}
