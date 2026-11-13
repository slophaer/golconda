# pcsc-lite, the daemon and client library a YubiKey is reached through on the release host
# (packages/yubikey-tools): the pin's version, the programs and the library with its header and
# pkg-config file, no systemd unit in it, and a daemon that runs: as an ordinary user, with the
# socket directory PCSCLITE_IPC_DIR names (no /run/pcscd in a build) and no readers, it makes its
# socket and pid file, says which driver directory it uses, and removes both when it ends.
use checks.nu *
let p = $env.pkg
let pcscd = $"($p)/bin/pcscd"

let v = (^$pcscd --version | complete)
assert $"pcscd --version names the pin: ($v.stdout) ($v.stderr)" ($"($v.stdout)($v.stderr)" | str contains "2.5.3")
assert "libpcsclite, the client library" ($"($p)/lib/libpcsclite.so.1" | path exists)
assert "and the library it forwards to" ($"($p)/lib/libpcsclite_real.so.1" | path exists)
assert "winscard.h, for the PIV tool" ($"($p)/include/PCSC/winscard.h" | path exists)
assert "the pkg-config file" ($"($p)/lib/pkgconfig/libpcsclite.pc" | path exists)
assert "no systemd unit, which would name the install prefix" (not ($"($p)/lib/systemd" | path exists))

let t = $"($env.TMPDIR? | default /tmp)/pcsc-lite-test"
rm -rf $t
mkdir $"($t)/run" $"($t)/drivers"
let log = $"($t)/pcscd.log"
$env.PCSCLITE_IPC_DIR = $"($t)/run"
$env.PCSCLITE_HP_DROPDIR = $"($t)/drivers"
job spawn { ^$pcscd --foreground --info out+err> $log } | ignore
let sock = $"($t)/run/pcscd.comm"
mut n = 0
while not ($sock | path exists) and $n < 100 {
  sleep 100ms
  $n += 1
}
assert $"pcscd makes its socket: (if ($log | path exists) { open --raw $log } else { 'no log' })" ($sock | path exists)
assert "and its pid file" ($"($t)/run/pcscd.pid" | path exists)
# the daemon writes the number, a newline and a NUL
let pid = (open --raw $"($t)/run/pcscd.pid" | parse -r '(?<pid>\d+)' | get pid.0 | into int)
kill $pid
$n = 0
while ($sock | path exists) and $n < 100 {
  sleep 100ms
  $n += 1
}
assert "it removes the socket when it ends" (not ($sock | path exists))
assert "it removes the pid file" (not ($"($t)/run/pcscd.pid" | path exists))
assert "it names the driver directory PCSCLITE_HP_DROPDIR gives" (open --raw $log | str contains $"Using drivers directory: ($t)/drivers")
done
