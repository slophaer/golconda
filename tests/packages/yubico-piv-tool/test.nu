# yubico-piv-tool with no YubiKey (a build has no token): the tool, libykpiv and libykcs11.so work
# up to the card. Without pcscd the tool says the service is not available; with pcscd and no
# reader (as an ordinary user, in a socket directory of its own) it reaches the daemon and finds
# no reader; libykcs11.so loads as a PKCS#11 module, p11-kit lists it, pkcs11-provider (the
# signer's loader) opens it, and it reports no slot and no token. The tool's help has the actions
# and options docs/reference/release.md uses.
use checks.nu *
let p = $env.pkg
let tool = $"($p)/bin/yubico-piv-tool"
let module = $"($p)/lib/libykcs11.so"

assert "the version is the pin" ((^$tool --version | str trim) | str contains "2.7.3")
assert "libykcs11.so" ($module | path exists)
assert "libykpiv" (ls $"($p)/lib" | get name | any {|f| $f =~ 'libykpiv\.so' })

let help = (^$tool --help | complete)
assert "--help succeeds" ($help.exit_code == 0)
# the actions and options the docs' steps use
for a in [change-pin change-puk set-mgm-key import-key import-certificate status] {
  assert $"the help lists ($a)" ($help.stdout | str contains $a)
}
for o in [--pin-policy --touch-policy --key-format --new-key --new-pin --pin] {
  assert $"the help lists ($o)" ($help.stdout | str contains $o)
}

let t = $"($env.TMPDIR? | default /tmp)/yubico-piv-tool-test"
rm -rf $t
mkdir $"($t)/run" $"($t)/drivers" $"($t)/xdg/pkcs11/modules"
$env.OPENSSL_CONF = "/dev/null"
$env.PCSCLITE_IPC_DIR = $"($t)/run"
$env.PCSCLITE_HP_DROPDIR = $"($t)/drivers"

# no pcscd yet: the tool and the module both say so
let nod = (^$tool -a status | complete)
assert "status without pcscd fails" ($nod.exit_code != 0)
assert $"libpcsclite finds its backend: ($nod.stderr)" (not ($nod.stderr | str contains "libpcsclite_real"))
assert $"and the tool says the service is missing: ($nod.stderr)" ($nod.stderr | str contains "PCSC service not available")
$env.OPENSSL_MODULES = $"($env.pkcs11-provider)/lib/ossl-modules"
$env.PKCS11_PROVIDER_MODULE = $module
$env.PATH = ($env.PATH | split row (char esep) | prepend [$"($env.openssl)/bin" $"($env.p11-kit)/bin"])
$env.YKCS11_DBG = "3"
let nodm = (^openssl storeutl -provider pkcs11 -provider default -keys "pkcs11:" | complete)
assert $"the module loads and says the service is missing: ($nodm.stderr)" ($nodm.stderr | str contains "PCSC service not available")

# pcscd with no reader
let log = $"($t)/pcscd.log"
job spawn { ^$"($env.pcsc-lite)/bin/pcscd" --foreground --info out+err> $log } | ignore
let sock = $"($t)/run/pcscd.comm"
mut n = 0
while not ($sock | path exists) and $n < 100 {
  sleep 100ms
  $n += 1
}
assert $"pcscd runs: (if ($log | path exists) { open --raw $log } else { 'no log' })" ($sock | path exists)

let st = (^$tool -a status | complete)
assert "status with no reader fails" ($st.exit_code != 0)
assert $"the tool reaches the daemon and finds no reader: ($st.stderr)" (not ($st.stderr | str contains "service not available"))

let sl = (^openssl storeutl -provider pkcs11 -provider default -keys "pkcs11:" | complete)
assert $"the module reports no slot: ($sl.stderr)" ($sl.stderr | str contains "number of slots is 0")
assert "and no key" (not ($sl.stdout | str contains "pkcs11:"))
$env.YKCS11_DBG = "0"

# p11-kit loads the module from a module file, as the user's configuration names one
$"module: ($module)\n" | save -f $"($t)/xdg/pkcs11/modules/ykcs11.module"
$env.XDG_CONFIG_HOME = $"($t)/xdg"
let pk = (^p11-kit list-modules | complete)
assert $"p11-kit lists the module: ($pk.stderr)" ($pk.exit_code == 0 and ($pk.stdout | str contains "library-description: PKCS#11 PIV Library"))
assert "it lists no token" (not ($pk.stdout | str contains "token:"))

let pid = (open --raw $"($t)/run/pcscd.pid" | parse -r '(?<pid>\d+)' | get pid.0 | into int)
kill $pid
done
