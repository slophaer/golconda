# smoke.nu: link a test image's outputs (lib/image/smoke.nix).
#
# Structured attrs: unsigned, signed, keys.

use common.nu *

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  mkdir $out
  ^ln -s $a.unsigned $"($out)/unsigned"
  ^ln -s $a.signed $"($out)/disk"
  ^ln -s $a.keys $"($out)/keys"
  log "unsigned, disk and keys linked"
}
