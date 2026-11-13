# The part of the ca-bundle build that decides which certificates are denied. It is its own file
# so that checks.ca-store-select runs it on bad input: a build that must fail cannot be a check of
# the build itself. package.nix puts this text in front of the install phase, so it holds `def`s
# only (the check `source`s it).

# PEM text -> the base64 of each certificate block, whitespace removed
def ca-blocks [text: string]: nothing -> list<string> {
  $text
  | parse --regex '(?s)-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----'
  | get capture0
  | each {|b| $b | str replace --all --regex '\s+' "" }
}

# the SHA-256 of the DER form of a certificate, as 64 lower-case hex digits, from its base64
def ca-fingerprint [block: string]: nothing -> string {
  $block | decode base64 | hash sha256
}

# From the roots (PEM text), the anchors (a list of PEM texts) and the distrust list (normalised
# SHA-256 fingerprints): `certs`, every distinct certificate, `denied`, those a fingerprint names,
# and `want`, the rest. An entry that is no fingerprint, or one that matches no certificate, is an
# error: a typo must not pass in silence.
def ca-select [roots: string, anchors: list<string>, distrust: list<string>]: nothing -> record {
  for e in $anchors {
    if (ca-blocks $e | length) != 1 {
      error make {msg: "ca-bundle: an anchors entry is not exactly one PEM certificate"}
    }
  }
  for e in $distrust {
    if ($e | parse --regex '^[0-9a-f]{64}$' | is-empty) {
      error make {msg: $"ca-bundle: a distrust entry is not a normalised SHA-256 fingerprint: ($e)"}
    }
  }
  let certs = ((ca-blocks $roots) ++ ($anchors | each {|e| ca-blocks $e } | flatten) | uniq)
  let known = ($certs | each {|b| {fp: (ca-fingerprint $b), pem: $b} })
  let unmatched = ($distrust | where {|d| not ($d in ($known | get fp)) })
  if ($unmatched | is-not-empty) {
    error make {msg: $"ca-bundle: distrust lists a fingerprint that matches no certificate of cacert or the anchors: ($unmatched | str join ', ')"}
  }
  let denied = ($known | where {|k| $k.fp in $distrust } | get pem)
  {certs: $certs, denied: $denied, want: ($certs | where {|b| not ($b in $denied) })}
}
