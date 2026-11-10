# smoke.nu: link a test image's outputs and write what the tools say about them
# (lib/image/smoke.nix).
#
# Structured attrs: unsigned, signed, keys.

use common.nu *

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  $env.LD_LIBRARY_PATH = $a.LD_LIBRARY_PATH
  mkdir $out
  ^ln -s $a.unsigned $"($out)/unsigned"
  ^ln -s $a.signed $"($out)/disk"
  ^ln -s $a.keys $"($out)/keys"

  let m = (open $"($a.unsigned)/manifest.json")
  let release = $"($a.signed)/release"
  let index = (open --raw $"($release)/SHA256SUMS" | lines | each {|l| $l | split row "  " | last })
  let usr = $"($release)/($index.0)"
  let hash = $"($release)/($index.1)"
  let sig = $"($release)/($index.2)"
  let uki = $"($release)/($index.3)"
  let initrd = $m.uki.initrd
  let roothash = (open --raw $sig | decode utf-8 | str replace -ra '\x00+$' '' | from json | get rootHash)
  mut lines = []
  $lines ++= ["== sizes"]
  for f in [$usr $hash $sig $initrd $uki $"($a.signed)/disk.raw"] {
    $lines ++= [$"(ls $f | get size.0 | into int) ($f)"]
  }
  $lines ++= ["" "== veritysetup verify"]
  let verify = (^veritysetup verify $usr $hash $roothash | complete)
  $lines ++= [$"exit ($verify.exit_code), root hash ($roothash)"]
  if $verify.exit_code != 0 {
    error make {msg: $"smoke: veritysetup verify failed: ($verify.stderr)"}
  }
  $lines ++= ["" "== initrd: first entries (bsdtar -t)"]
  $lines ++= (^bsdtar -tf $initrd | lines | first 12)
  $lines ++= [$"... (^bsdtar -tf $initrd | lines | length) entries"]
  $lines ++= ["" "== ukify inspect"]
  $lines ++= (^ukify inspect $uki | lines)
  $lines ++= ["" "== systemd-repart --json=pretty (when signed)"]
  $lines ++= (open --raw $"($a.signed)/disk.json" | from json | each {|p| $"($p.type) ($p.label? | default '-') offset ($p.offset) size ($p.raw_size) uuid ($p.uuid)" })
  $lines | str join "\n" | save -f $"($out)/proof.txt"
  log "proof.txt written"
}
