# swtpm as scripts/boot-test starts it (scripts/boot-test-vm.sh, start_tpm): `swtpm socket --tpm2`
# on an empty state directory, with a control socket. The test adds a data socket and talks TPM 2.0
# to it: swtpm_ioctl initialises the TPM over the control channel (what QEMU's emulator backend
# does), swtpm_bios sends TPM2_Startup over the data channel, and swtpm_ioctl asks for the TPM's
# specification and shuts it down. The TPM writes its state, so libtpms ran the commands.
use checks.nu *
let bin = $"($env.pkg)/bin"
let t = $"($env.TMPDIR? | default /tmp)/swtpm-test"
rm -rf $t
mkdir $t
mkdir $"($t)/state"

let v = (^$"($bin)/swtpm" --version | lines | first)
assert $"version is the pin: ($v)" ($v | str contains "0.10.2")
# the capabilities are JSON (json-glib); a TPM 2.0 build without the CUSE interface
let caps = (^$"($bin)/swtpm" socket --tpm2 --print-capabilities | from json)
assert $"the TPM 2.0 is there: ($caps)" ("tpm-2.0" in $caps.features)

let ctrl = $"($t)/ctrl"
let srv = $"($t)/srv"
let pid = (^sh -c $"'($bin)/swtpm' socket --tpm2 --tpmstate dir='($t)/state' --ctrl type=unixio,path='($ctrl)' --server type=unixio,path='($srv)' > '($t)/swtpm.log' 2>&1 & echo $!" | str trim)
mut up = false
for _ in 1..50 {
  if ($ctrl | path exists) and ($srv | path exists) { $up = true; break }
  sleep 100ms
}
assert $"swtpm made its sockets: (open --raw $'($t)/swtpm.log')" $up

let init = (^$"($bin)/swtpm_ioctl" --unix $ctrl -i | complete)
assert $"swtpm_ioctl -i initialises the TPM: ($init.stdout) ($init.stderr)" ($init.exit_code == 0)
let startup = (^$"($bin)/swtpm_bios" --tpm2 --unix $srv | complete)
assert $"swtpm_bios sends TPM2_Startup: ($startup.stdout) ($startup.stderr)" ($startup.exit_code == 0)
let info = (^$"($bin)/swtpm_ioctl" --unix $ctrl --info 1 | from json)
assert $"the TPM is a 2.0 one: ($info)" ($info.TPMSpecification.family == "2.0")
let stop = (^$"($bin)/swtpm_ioctl" --unix $ctrl -s | complete)
assert $"swtpm_ioctl -s shuts it down: ($stop.stderr)" ($stop.exit_code == 0)

mut gone = false
for _ in 1..50 {
  # gone, or a zombie: nothing in the sandbox reaps it (its parent sh has ended)
  let state = (try { open --raw $"/proc/($pid)/stat" | split row " " | get 2 } catch { "gone" })
  if $state in [gone Z X] { $gone = true; break }
  sleep 100ms
}
assert "swtpm ends after the shutdown" $gone
assert "the TPM wrote its state" ($"($t)/state/tpm2-00.permall" | path exists)

rm -rf $t
done
