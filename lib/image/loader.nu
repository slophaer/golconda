# loader.nu: systemd-boot signed for Secure Boot, a step of the signer (lib/image/sign.nu).

use common.nu *

# sign UNSIGNED OUT KEY CERT: enforcing firmware starts only a loader signed by a key in db; a
# signing failure fails the release
export def sign [unsigned: string, out: string, key: string, cert: string] {
  ^systemd-sbsign sign $unsigned --private-key $key --certificate $cert --output $out
  log $"($out | path basename): signed, (ls $out | get size.0)"
}
