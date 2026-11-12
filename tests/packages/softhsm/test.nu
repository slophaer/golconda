# softhsm (TEST-ONLY) as the signer's tests use it: a token in a directory of the test's own,
# named by SOFTHSM2_CONF, and an RSA key that openssl made, imported under a label and an id. The
# token lists the key's private and public objects, and the module is where callers load it.
use checks.nu *
# openssl, from the package that inputs.nix names
$env.PATH = ($env.PATH | split row (char esep) | prepend [$"($env.openssl)/bin"])
let p = $env.pkg
let t = $"($env.TMPDIR? | default /tmp)/softhsm-test"
rm -rf $t
mkdir $"($t)/tokens"
$"directories.tokendir = ($t)/tokens\nobjectstore.backend = file\nlog.level = ERROR\n" | save -f $"($t)/softhsm2.conf"
$env.SOFTHSM2_CONF = $"($t)/softhsm2.conf"
$env.OPENSSL_CONF = "/dev/null"
let module = $"($p)/lib/softhsm/libsofthsm2.so"
let util = $"($p)/bin/softhsm2-util"

assert "version is the pin" ((^$util --version | str trim) == "2.7.0")
assert "the module callers load" ($module | path exists)

let init = (^$util --module $module --init-token --free --label golconda-test --pin 1234 --so-pin 5678 | complete)
assert $"init-token succeeds: ($init.stderr)" ($init.exit_code == 0)
^openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out $"($t)/key.pem" e> /dev/null
let imp = (^$util --module $module --import $"($t)/key.pem" --token golconda-test --label db --id 01 --pin 1234 | complete)
assert $"import succeeds: ($imp.stdout) ($imp.stderr)" ($imp.exit_code == 0)
let slots = (^$util --module $module --show-slots | complete)
assert "the token is listed" ($slots.stdout | str contains "golconda-test")
let wrong = (^$util --module $module --import $"($t)/key.pem" --token golconda-test --label db2 --id 02 --pin 0000 | complete)
assert "a wrong PIN is refused" ($wrong.exit_code != 0)
done
