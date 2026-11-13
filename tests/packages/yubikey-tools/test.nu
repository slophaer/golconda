# yubikey-tools, the release host's one PATH: pcscd, yubico-piv-tool and ykcs11-module. Each is a
# launcher of one of this package's scripts and runs the tool of a dependency: pcscd (as an
# ordinary user here, in a socket directory of its own, with no reader) uses ccid's driver
# directory, which only the launcher's environment names; yubico-piv-tool answers; ykcs11-module
# prints the path of the module that yubico-piv-tool's package holds.
use checks.nu *
let p = $env.pkg
let bin = $"($p)/bin"
for n in [pcscd yubico-piv-tool ykcs11-module] {
  assert $"bin/($n)" ($"($bin)/($n)" | path exists)
}

let v = (^$"($bin)/yubico-piv-tool" --version | complete)
assert $"yubico-piv-tool runs: ($v.stderr)" ($v.exit_code == 0 and ($v.stdout | str contains "2.7.3"))
let module = (^$"($bin)/ykcs11-module" | str trim)
assert $"ykcs11-module prints the module: ($module)" (($module | str ends-with "/libykcs11.so") and ($module | path exists))
assert "it is yubico-piv-tool's" ((($module | path expand) | str starts-with ($env.yubico-piv-tool | path expand)))

let t = $"($env.TMPDIR? | default /tmp)/yubikey-tools-test"
rm -rf $t
mkdir $"($t)/run"
let log = $"($t)/pcscd.log"
$env.PCSCLITE_IPC_DIR = $"($t)/run"
# PCSCLITE_HP_DROPDIR is not set here: the launcher sets it from ccid
hide-env -i PCSCLITE_HP_DROPDIR
job spawn { ^$"($bin)/pcscd" --foreground --info out+err> $log } | ignore
let sock = $"($t)/run/pcscd.comm"
mut n = 0
while not ($sock | path exists) and $n < 100 {
  sleep 100ms
  $n += 1
}
assert $"pcscd runs: (if ($log | path exists) { open --raw $log } else { 'no log' })" ($sock | path exists)
let text = (open --raw $log)
assert $"it uses ccid's driver directory: ($text)" ($text =~ 'Using drivers directory: .*-ccid/lib/pcsc/drivers')
assert $"and finds the bundle there: ($text)" (not ($text | str contains "No bundle files"))
let pid = (open --raw $"($t)/run/pcscd.pid" | parse -r '(?<pid>\d+)' | get pid.0 | into int)
kill $pid
done
