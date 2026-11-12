# pkcs11-provider as the signer uses it (lib/image/sign.nu use-token): openssl loads it from
# OPENSSL_MODULES, with the parameters of an OpenSSL configuration: the PKCS#11 module (softhsm,
# TEST-ONLY) and no digests from the token. A key on the token signs by its `pkcs11:` URI. The
# signature verifies with the public half alone, is the same bytes as the file key's (RSA PKCS#1
# v1.5 draws no random numbers, so a release signed from a token is the release signed from
# files), and does not verify with another key.
use checks.nu *
# openssl and softhsm2-util, from the packages that inputs.nix names
$env.PATH = ($env.PATH | split row (char esep) | prepend [$"($env.openssl)/bin" $"($env.softhsm)/bin"])
let p = $env.pkg
let t = $"($env.TMPDIR? | default /tmp)/pkcs11-provider-test"
rm -rf $t
mkdir $"($t)/tokens"
$"directories.tokendir = ($t)/tokens\nobjectstore.backend = file\nlog.level = ERROR\n" | save -f $"($t)/softhsm2.conf"
$env.SOFTHSM2_CONF = $"($t)/softhsm2.conf"
let softhsm = $env.softhsm
let module = $"($softhsm)/lib/softhsm/libsofthsm2.so"
$env.OPENSSL_MODULES = $"($p)/lib/ossl-modules"
# softhsm hashes the PIN with OpenSSL's digests in this process: from the token, they would call
# back into softhsm during its own C_Login, which waits for ever
[
  "openssl_conf = openssl_init"
  "[openssl_init]"
  "providers = provider_sect"
  "[provider_sect]"
  "default = default_sect"
  "pkcs11 = pkcs11_sect"
  "[default_sect]"
  "activate = 1"
  "[pkcs11_sect]"
  $"pkcs11-module-path = ($module)"
  "pkcs11-module-block-operations = digest"
] | str join "\n" | save -f $"($t)/openssl.cnf"
$env.OPENSSL_CONF = $"($t)/openssl.cnf"

assert "the provider module" ($"($p)/lib/ossl-modules/pkcs11.so" | path exists)

^softhsm2-util --module $module --init-token --free --label golconda-test --pin 1234 --so-pin 5678 | ignore
for k in [a b] {
  ^openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out $"($t)/($k).pem" e> /dev/null
  ^openssl pkey -in $"($t)/($k).pem" -pubout -out $"($t)/($k).pub"
}
^softhsm2-util --module $module --import $"($t)/a.pem" --token golconda-test --label db --id 01 --pin 1234 | ignore

let uri = "pkcs11:token=golconda-test;object=db;type=private?pin-value=1234"
let prov = [-provider pkcs11 -provider default]
"release payload\n" | save -f $"($t)/msg"

# the public half, read from the token (PKCS#1, which openssl turns into the file's form)
let pub = (^openssl pkey ...$prov -in $uri -pubout -outform DER -out $"($t)/token.der" | complete)
assert $"the token's key gives its public half: ($pub.stderr)" ($pub.exit_code == 0)
let spki = (^openssl pkey -pubin -inform DER -in $"($t)/token.der" -pubout)
assert "it is the imported key's" ($spki == (^openssl pkey -pubin -in $"($t)/a.pub" -pubout))

let sign = (^openssl dgst -sha256 ...$prov -sign $uri -out $"($t)/sig" $"($t)/msg" | complete)
assert $"signing with the token's key succeeds: ($sign.stderr)" ($sign.exit_code == 0)
let ok = (^openssl dgst -sha256 -verify $"($t)/a.pub" -signature $"($t)/sig" $"($t)/msg" | complete)
assert $"the signature verifies with the public half: ($ok.stdout)" ($ok.exit_code == 0)
^openssl dgst -sha256 -sign $"($t)/a.pem" -out $"($t)/sig-file" $"($t)/msg"
assert "the token's signature is the file key's, byte for byte" ((open --raw $"($t)/sig" | hash sha256) == (open --raw $"($t)/sig-file" | hash sha256))
let other = (^openssl dgst -sha256 -verify $"($t)/b.pub" -signature $"($t)/sig" $"($t)/msg" | complete)
assert "it does not verify with another key" ($other.exit_code != 0)

let nopin = (^openssl dgst -sha256 ...$prov -sign "pkcs11:token=golconda-test;object=db;type=private?pin-value=0000" -out $"($t)/sig2" $"($t)/msg" | complete)
assert "a wrong PIN signs nothing" ($nopin.exit_code != 0)
done
