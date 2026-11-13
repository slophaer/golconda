# enrol-main.nu: golconda-enrol-auth, the program that writes a key set's enrolment files
# (lib/image/signer.nix enrolTool runs this file; lib/image/enrol.nu writes them).
#
#   golconda-enrol-auth --keys DIR [--signing-keys OLD] [--epoch N]
#
# DIR is a key set in scripts/make-keys' layout. The program reads its secureboot/PK.crt, KEK.crt
# and db.crt and writes secureboot/auth/microsoft/ and secureboot/auth/golconda/. The PK and KEK
# keys that sign are DIR's, or OLD's with --signing-keys (a db rotation keeps the old PK and KEK:
# DIR then holds copies of OLD's certificates and no PK or KEK key). Microsoft's objects come from
# GOLCONDA_SECUREBOOT_OBJECTS (packages/secureboot-objects, set by the program). --epoch is the
# time in the files (default: now). scripts/make-keys runs it; run it again for a newer dbx.

use enrol.nu

def main [
  --keys: string # the key set whose certificates are enrolled
  --signing-keys: string # the set whose secureboot/PK.key and KEK.key sign (default: --keys)
  --epoch: int # the EFI_TIME of the files, seconds since 1970 (default: now)
] {
  if $keys == null {
    error make {msg: "usage: golconda-enrol-auth --keys DIR [--signing-keys OLD] [--epoch N]"}
  }
  let sb = ($keys | path join secureboot | path expand)
  let signing = ($signing_keys | default $keys | path join secureboot | path expand)
  let epoch = ($epoch | default (date now | format date "%s" | into int))
  let ms = $env.GOLCONDA_SECUREBOOT_OBJECTS
  (enrol write $"($sb)/auth"
    {pk: $"($sb)/PK.crt" kek: $"($sb)/KEK.crt" db: $"($sb)/db.crt"}
    {pkKey: $"($signing)/PK.key" pkCert: $"($signing)/PK.crt" kekKey: $"($signing)/KEK.key" kekCert: $"($signing)/KEK.crt"}
    $ms $epoch)
}
