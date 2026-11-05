# smoke.nu: collect the chain's outputs and write what the tools say about them
# (lib/image/smoke.nix).
#
# Structured attrs: erofs, verity, initrd, uki, disk, keys, stem.

use common.nu *

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  $env.LD_LIBRARY_PATH = $a.LD_LIBRARY_PATH
  mkdir $out
  for s in [erofs verity initrd uki disk keys] { ^ln -s ($a | get $s) $"($out)/($s)" }

  let usr = $"($a.erofs)/($a.stem).usr.raw"
  let hash = $"($a.verity)/($a.stem).usr-verity.raw"
  let roothash = (open --raw $"($a.verity)/roothash")
  mut lines = []
  $lines ++= ["== sizes"]
  for f in [$usr $hash $"($a.verity)/($a.stem).usr-verity-sig.raw" $"($a.initrd)/initrd.cpio.zst" (glob $"($a.uki)/*.efi" | sort | first) $"($a.disk)/disk.raw"] {
    $lines ++= [$"(ls $f | get size.0 | into int) ($f)"]
  }
  $lines ++= ["" "== veritysetup verify"]
  let verify = (^veritysetup verify $usr $hash $roothash | complete)
  $lines ++= [$"exit ($verify.exit_code), root hash ($roothash)"]
  if $verify.exit_code != 0 {
    error make {msg: $"smoke: veritysetup verify failed: ($verify.stderr)"}
  }
  $lines ++= ["" "== initrd: first entries (bsdtar -t)"]
  $lines ++= (^bsdtar -tf $"($a.initrd)/initrd.cpio.zst" | lines | first 12)
  $lines ++= [$"... (^bsdtar -tf $"($a.initrd)/initrd.cpio.zst" | lines | length) entries, rdinit=(open --raw $"($a.initrd)/rdinit")"]
  $lines ++= ["" "== ukify inspect"]
  $lines ++= (^ukify inspect (glob $"($a.uki)/*.efi" | sort | first) | lines)
  $lines ++= ["" "== systemd-repart --json=pretty (at build)"]
  $lines ++= (open --raw $"($a.disk)/disk.json" | from json | each {|p| $"($p.type) ($p.label? | default '-') offset ($p.offset) size ($p.raw_size) uuid ($p.uuid)" })
  $lines | str join "\n" | save -f $"($out)/proof.txt"
  log "proof.txt written"
}
