# The distrust arithmetic of the ca-bundle build (packages/ca-bundle/select.nu), on cacert's real
# roots and the fixtures: a Mozilla root is denied by its fingerprint, an anchor too, and a
# fingerprint that matches nothing, or is no fingerprint, is an error.
#
# usage (checks.ca-store-select sources packages/ca-bundle/select.nu first):
#   nu --no-config-file -c 'source packages/ca-bundle/select.nu; source tests/ca-store/select.nu'
# with FIXTURES (tests/fixtures/ca-store) and CACERT (cacert's ca-bundle.crt) in the environment.

let fixtures = $env.FIXTURES
let roots = (open --raw $env.CACERT)
let fp = (open $"($fixtures)/fingerprints.json")
let anchor = (open --raw $"($fixtures)/anchor-ca.crt")
let other = (open --raw $"($fixtures)/distrusted-ca.crt")
let n_roots = (ca-blocks $roots | uniq | length)

def --env report [name: string, ok: bool] {
  print $"(if $ok { 'PASS' } else { 'FAIL' }): ($name)"
  if not $ok { $env.FAILED = true }
}
$env.FAILED = false

# the message of the error a closure raises, or null when it returns
def failure [f: closure]: nothing -> any {
  try { do $f; null } catch {|e| $e.msg }
}

let none = (ca-select $roots [] [])
report "with an empty list, nothing is denied and the roots are all wanted" (
  ($none.denied | is-empty) and ($none.want | length) == $n_roots and $n_roots > 100
)

# COMODO ECC Certification Authority, a real root of cacert, by the fingerprint openssl prints
let comodo = "1793927a0614549789adce2f8f34f7f0b66d0f3ae3a3b84d21ec15dbba4fadc7"
let one = (ca-select $roots [] [$comodo])
report "a Mozilla root is denied by its fingerprint, the other roots stay" (
  ($one.denied | length) == 1 and ($one.want | length) == ($n_roots - 1)
  and (ca-fingerprint $one.denied.0) == $comodo
)
report "the fixture's fingerprint of that root is the one cacert has" (
  $fp.mozilla-root == $comodo
)

let with_anchor = (ca-select $roots [$anchor $other] [$fp.distrusted-ca])
report "an anchor is denied by its fingerprint, another anchor stays" (
  ($with_anchor.want | length) == $n_roots + 1 and ($with_anchor.denied | length) == 1
)

let typo = ($comodo | str replace --regex '.$' '0')
let m = (failure {|| ca-select $roots [] [$comodo $typo] })
report "a fingerprint that matches no certificate fails, and the message names it" (
  $m != null and ($m | str contains $typo) and ($m | str contains "matches no certificate")
)
report "an anchor's fingerprint matches nothing when the anchor is not listed" (
  (failure {|| ca-select $roots [] [$fp.anchor-ca] }) != null
)
report "an entry that is not a normalised fingerprint fails" (
  (failure {|| ca-select $roots [] [($comodo | str uppercase)] }) != null
  and (failure {|| ca-select $roots [] ["abc"] }) != null
)
report "an anchors entry that is not one certificate fails" (
  (failure {|| ca-select $roots ["junk"] [] }) != null
)
if $env.FAILED { exit 1 }
