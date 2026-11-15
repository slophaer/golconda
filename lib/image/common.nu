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

# pgp-keys FILE KIND: the one OpenPGP key of KIND (pub: a public keyring, sec: a secret key)
# in FILE, as {fpr created}; any other count is an error. gpg reads the file in a home of its
# own and imports nothing
export def pgp-keys [file: string, kind: string]: nothing -> record {
  let home = (mktemp -d -t "golconda-gnupg-XXXXXX")
  ^chmod 700 $home
  let r = (with-env {GNUPGHOME: $home} { do { ^gpg --batch --with-colons --show-keys $file } | complete })
  rm -rf $home
  let rows = ($r.stdout | lines)
  let count = {|k| $rows | where {|l| $l starts-with $"($k):" } | length }
  let other = if $kind == "pub" { "sec" } else { "pub" }
  if $r.exit_code != 0 or (do $count $kind) != 1 or (do $count $other) != 0 {
    error make {msg: $"($file): expected one ($kind) OpenPGP key and no other, found (do $count 'pub') pub and (do $count 'sec') sec; scripts/make-keys writes the release key as release/index.pgp and release/index.key"}
  }
  # the first fpr line follows the primary key
  {
    fpr: ($rows | where {|l| $l starts-with "fpr:" } | first | split row ':' | get 9)
    created: ($rows | where {|l| $l starts-with $"($kind):" } | first | split row ':' | get 5 | into int)
  }
}
