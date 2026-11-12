# ca-bundle: with no anchors and no distrust list (the package as the set builds it), the file is
# cacert's roots as one PEM bundle: only certificate blocks, each root once, nothing else. The
# build itself compares the bundle with cacert's (packages/ca-bundle), so this test reads the file
# alone; what the options do is checks.ca-store (tests/ca-store).
use checks.nu *
let f = $"($env.pkg)/share/ca-certificates/ca-bundle.crt"
assert "the bundle is at share/ca-certificates, where /trust links it from" ($f | path exists)

let text = (open --raw $f)
let blocks = ($text | parse --regex '(?s)-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----' | get capture0
  | each {|b| $b | str replace --all --regex '\s+' "" })
assert $"it holds Mozilla's roots, not a stub: ($blocks | length) certificates" (($blocks | length) > 100)
assert "every root is there once" (($blocks | length) == ($blocks | uniq | length))

let rest = ($text | str replace --all --regex '(?s)-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----' "" | str trim)
assert "nothing but certificate blocks: no key, no trust-settings block, no comment" ($rest == "")
assert "plain CERTIFICATE blocks, the form every TLS client reads" (not ($text | str contains "TRUSTED CERTIFICATE"))

# a root the check of /trust distrusts (tests/fixtures/ca-store/mozilla-root.crt): it must be in
# the default bundle, or that check would pass without testing anything
assert "COMODO ECC Certification Authority is in the default bundle" (
  $blocks | any {|b| $b | str starts-with "MIICiTCCAg+gAwIBAgIQH0evqmIAcFBUTAGem2OZKjAKBggqhkjOPQQDAzCBhTEL" }
)
done
