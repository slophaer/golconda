# sign-main.nu: golconda-sign, the signer's command line (lib/image/signer.nix makes the program
# that runs this file; lib/image/sign.nu is the signer).
#
#   golconda-sign UNSIGNED --keys DIR [--pcr-keys DIR] [--index-keys DIR] --out DIR
#
# UNSIGNED is the unsigned output of lib.mkImage (`unsigned`: manifest.json). --keys is the key
# set (scripts/make-keys); --pcr-keys and --index-keys name other sets for the PCR key and the
# release key, which a db rotation keeps (docs/reference/release.md). OUT gets disk.raw,
# disk.json, release/ and cmdline.

use sign.nu

def main [
  unsigned: path # lib.mkImage's `unsigned` output
  --keys: string # the key set: secureboot/db.key, and pcr/ and release/ unless named below
  --pcr-keys: string # the set whose pcr/pcr.key signs the PCR policy (default: --keys)
  --index-keys: string # the set whose release/index.key signs SHA256SUMS (default: --keys)
  --out: path # where the release goes
] {
  if $keys == null or $out == null {
    error make {msg: "usage: golconda-sign UNSIGNED --keys DIR [--pcr-keys DIR] [--index-keys DIR] --out DIR"}
  }
  sign $unsigned {db: $keys pcr: ($pcr_keys | default $keys) index: ($index_keys | default $keys)} $out
}
