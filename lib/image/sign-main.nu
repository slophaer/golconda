# sign-main.nu: golconda-sign, the signer's command line (lib/image/signer.nix makes the program
# that runs this file; lib/image/sign.nu is the signer).
#
#   golconda-sign UNSIGNED --keys DIR [--pcr-keys DIR] [--index-keys DIR]
#     [--pkcs11-module FILE] --out DIR
#
# UNSIGNED is the unsigned output of lib.mkImage (`unsigned`: manifest.json). --keys is the key
# set (scripts/make-keys); --pcr-keys and --index-keys name other sets for the PCR key and the
# release key, which a db rotation keeps (docs/reference/release.md). A set may hold the db and
# PCR keys on a PKCS#11 token (secureboot/db.pkcs11, pcr/pcr.pkcs11: a URI each); FILE is then the
# token's PKCS#11 module. OUT gets disk.raw, disk.json, release/ and cmdline.

use sign.nu

def main [
  unsigned: path # lib.mkImage's `unsigned` output
  --keys: string # the key set: secureboot/db.key, and pcr/ and release/ unless named below
  --pcr-keys: string # the set whose pcr/pcr.key signs the PCR policy (default: --keys)
  --index-keys: string # the set whose release/index.key signs SHA256SUMS (default: --keys)
  --pkcs11-module: path # the PKCS#11 module of the token a key set names keys on
  --out: path # where the release goes
] {
  if $keys == null or $out == null {
    error make {msg: "usage: golconda-sign UNSIGNED --keys DIR [--pcr-keys DIR] [--index-keys DIR] [--pkcs11-module FILE] --out DIR"}
  }
  sign $unsigned {db: $keys pcr: ($pcr_keys | default $keys) index: ($index_keys | default $keys)} $out $pkcs11_module
}
