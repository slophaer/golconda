# common.nu: what every image step's builder shares (lib/image/common.nix runs them).

# The structured attrs of the derivation
export def attrs [] {
  open $env.NIX_ATTRS_JSON_FILE
}

# A line on stderr, prefixed with the step
export def log [msg: string] {
  print -e $"image: ($msg)"
}

# Zero-pad a file to a multiple of `block` bytes (systemd-repart wants CopyBlocks sources in
# whole sectors; the verity signature partition is read up to its first NUL)
export def pad-to [file: path, block: int] {
  let size = (ls $file | get size.0 | into int)
  let want = ((($size + $block - 1) / $block | math floor) * $block)
  if $want > $size {
    ^truncate -s $want $file
  }
}
