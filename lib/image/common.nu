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

# Keys on a PKCS#11 token (lib/image/sign.nu): a private key is a file path or a `pkcs11:` URI,
# and the tools take a URI through pkcs11-provider (use-token in sign.nu loads it)
export def on-token [key: string]: nothing -> bool {
  $key | str starts-with "pkcs11:"
}

# openssl's arguments for KEY: the default provider and pkcs11-provider when it is on a token.
# The default provider first: it serves the digests (sign.nu use-token)
export def openssl-key-source [key: string]: nothing -> list<string> {
  if (on-token $key) { [-provider default -provider pkcs11] } else { [] }
}

# systemd-sbsign's and systemd-measure's arguments for KEY on a token (systemd 262:
# --private-key-source=provider:NAME takes the key argument as the provider's URI)
export def systemd-key-source [key: string]: nothing -> list<string> {
  if (on-token $key) { [--private-key-source provider:pkcs11] } else { [] }
}
