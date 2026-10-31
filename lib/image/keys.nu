# keys.nu: throwaway key pairs for the smoke (lib/image/default.nix throwawayKeys).
#
# Output, after image/default.nix keys: secureboot/db.{key,crt}, verity/verity.{key,crt},
# pcr/pcr.key and pcr/pcr.pub (the public key ukify embeds as .pcrpkey), and
# ssh-ca/ca and ssh-ca/ca.pub (SSH user CA for the boot test).

use common.nu *

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  # repkgs' openssl reads /etc/ssl/openssl.cnf (OPENSSLDIR); there is none in the sandbox
  $env.OPENSSL_CONF = "/dev/null"
  for pair in [[dir name cn]; [secureboot db "Golconda smoke Secure Boot db"] [verity verity "Golconda smoke verity"]] {
    mkdir $"($out)/($pair.dir)"
    ^openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj $"/CN=($pair.cn)/" -keyout $"($out)/($pair.dir)/($pair.name).key" -out $"($out)/($pair.dir)/($pair.name).crt" e> /dev/null
    log $"($pair.dir)/($pair.name).key, .crt"
  }
  mkdir $"($out)/pcr"
  ^openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out $"($out)/pcr/pcr.key" e> /dev/null
  ^openssl pkey -in $"($out)/pcr/pcr.key" -pubout -out $"($out)/pcr/pcr.pub"
  log "pcr/pcr.key, .pub"

  # SSH test key for boot testing: the test uses this key to log in.
  # The image trusts ssh-test/key.pub as an authorizedKey.
  mkdir $"($out)/ssh-test"
  ^ssh-keygen -q -t ed25519 -N '' -f $"($out)/ssh-test/key" -C "golconda-boot-test"
  log "ssh-test/key, .pub"
}
