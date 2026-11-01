# loader.nu: systemd-boot signed for Secure Boot (lib/image/loader.nix).
#
# Structured attrs: systemdBoot (the unsigned loader), fileName, sbKey, sbCert.

use common.nu *

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  $env.LD_LIBRARY_PATH = $a.LD_LIBRARY_PATH
  mkdir $out
  # enforcing firmware starts only a loader signed by a key in db; a signing failure fails the
  # build
  ^systemd-sbsign sign $a.systemdBoot --private-key $a.sbKey --certificate $a.sbCert --output $"($out)/($a.fileName)"
  log $"($a.fileName): signed with ($a.sbCert | path basename), (ls $"($out)/($a.fileName)" | get size.0)"
}
