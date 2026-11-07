# Exercise the package's actual phases with a stub tree, without compiling Linux.
use ../../packages/kernel/kbuild.nu
const FIXTURES = path self .

let pwd = $env.PWD
let root = (mktemp -d -t kernel-test.XXXX)
mkdir $"($root)/source/arch/x86/boot" $"($root)/build" $"($root)/out" $"($root)/debug"
"kernel\n" | save $"($root)/source/arch/x86/boot/bzImage"
"symbols\n" | save $"($root)/source/System.map"
"CONFIG_BASE=y\n" | save $"($root)/source/.config"
"unstripped kernel\n" | save $"($root)/source/vmlinux"
"kernelversion:\n\t@printf '6.18-test\\n'\n" | save $"($root)/source/Makefile"
{outputs: {out: $"($root)/out", debug: $"($root)/debug"}} | to json | save $"($root)/attrs.json"
$env.NIX_ATTRS_JSON_FILE = $"($root)/attrs.json"
$env.PKGS_CTX = {
  spec: {env: {GOLCONDA_KERNEL_CONFIG: "{}", GOLCONDA_KERNEL_EXTRA_CONFIG: "{}", GOLCONDA_KERNEL_FRAGMENTS: "[]", GOLCONDA_KERNEL_MAKE: "[]", GOLCONDA_KERNEL_FILES: "{}"}}
  out: $"($root)/out", dest: $"($root)/out", deps: [], roots: [], njobs: 1,
  src: $"($root)/source", build: $"($root)/build",
  platform: {cpu: x86_64, names: {kernel: x86}}, testsRun: false, cache: false
}
cd $"($root)/source"
kbuild install
if not ($"($root)/out/lib/modules/6.18-test/vmlinuz" | path exists) { error make {msg: "kernel image missing"} }
if not ($"($root)/debug/lib/debug/vmlinux" | path exists) { error make {msg: "debug vmlinux missing"} }
if (open --raw $"($root)/debug/lib/debug/vmlinux") != "unstripped kernel\n" { error make {msg: "debug vmlinux changed"} }
if ($"($root)/out/lib/modules/6.18-test/trusted-keys.pem" | path exists) { error make {msg: "a kernel without built-in keys recorded some"} }
mkdir $"($root)/source/scripts/kconfig"
cp ($FIXTURES | path join Makefile) $"($root)/source/Makefile" --force
cp ($FIXTURES | path join merge_config.sh) $"($root)/source/scripts/kconfig/merge_config.sh"
let config = {BASE: y, NUMBER: 42, TEXT: 'a"b', OFF: n}
$env.PKGS_CTX = ($env.PKGS_CTX | upsert spec.env.GOLCONDA_KERNEL_CONFIG ($config | to json))
kbuild configure
kbuild build
# the compressed kernel's digest on piggy.o's command line; no built-in keys, no flag for them
let digest = (open --raw $"($root)/source/vmlinux" | hash sha256)
if (open --raw $"($root)/source/incbin-flags" | lines) != ["" $"-DGOLCONDA_INCBIN_SHA256=($digest)"] {
  error make {msg: $"incbin digests wrong without built-in keys: (open --raw $"($root)/source/incbin-flags")"}
}
let lines = (open --raw $"($root)/source/.config" | lines)
for want in ["CONFIG_BASE=y" "CONFIG_NUMBER=42" 'CONFIG_TEXT="a\"b"' "# CONFIG_OFF is not set"] {
  if $want not-in $lines { error make {msg: $"config serialization lost ($want)"} }
}
"CONFIG_BASE=m\n" | save $"($root)/policy.config"
$env.PKGS_CTX = ($env.PKGS_CTX | upsert spec.env.GOLCONDA_KERNEL_FRAGMENTS ([$"($root)/policy.config"] | to json))
kbuild configure
let merged = (open --raw $"($root)/source/.config" | lines)
if "CONFIG_BASE=m" not-in $merged or "CONFIG_BASE=y" in $merged { error make {msg: "policy fragment did not override typed base"} }
let dropped = (with-env {DROP_NUMBER: "1"} {
  try { kbuild configure; {failed: false} } catch {|e| {failed: true, message: $e.msg} }
})
if not $dropped.failed or not ($dropped.message | str contains "CONFIG_NUMBER") {
  error make {msg: "olddefconfig losing an option did not fail verification"}
}
# extra config: merged over the base and verified after the fragments
$env.PKGS_CTX = ($env.PKGS_CTX | upsert spec.env.GOLCONDA_KERNEL_EXTRA_CONFIG ({NUMBER: 7, EXTRA: y} | to json))
kbuild configure
let extra = (open --raw $"($root)/source/.config" | lines)
if "CONFIG_NUMBER=7" not-in $extra or "CONFIG_NUMBER=42" in $extra or "CONFIG_EXTRA=y" not-in $extra {
  error make {msg: $"extra config not merged over the base: ($extra)"}
}
# a fragment that contradicts a required extra option fails the build
$env.PKGS_CTX = ($env.PKGS_CTX | upsert spec.env.GOLCONDA_KERNEL_EXTRA_CONFIG ({BASE: y} | to json))
let conflict = (try { kbuild configure; {failed: false} } catch {|e| {failed: true, message: $e.msg} })
if not $conflict.failed or not ($conflict.message | str contains "CONFIG_BASE") {
  error make {msg: "a fragment silently overrode a required extra option"}
}
$env.PKGS_CTX = ($env.PKGS_CTX | upsert spec.env.GOLCONDA_KERNEL_EXTRA_CONFIG "{}")
# files: copied into the tree before configure, at the path the config names
"test certificate\n" | save $"($root)/db.crt"
let files = {"certs/golconda-verity.pem": $"($root)/db.crt"}
$env.PKGS_CTX = ($env.PKGS_CTX | upsert spec.env.GOLCONDA_KERNEL_FILES ($files | to json))
kbuild configure
if (open --raw $"($root)/source/certs/golconda-verity.pem") != "test certificate\n" {
  error make {msg: "the kernel file was not copied into the tree"}
}
# refused: a path the tree already has, a path outside the tree, a source that does not exist
for bad in [
  [$files "already has it"]
  [{"../escape.pem": $"($root)/db.crt"} "inside the tree"]
  [{"/abs.pem": $"($root)/db.crt"} "inside the tree"]
  [{"certs/missing.pem": $"($root)/missing.crt"} "does not exist"]
] {
  $env.PKGS_CTX = ($env.PKGS_CTX | upsert spec.env.GOLCONDA_KERNEL_FILES ($bad.0 | to json))
  let r = (try { kbuild configure; {failed: false} } catch {|e| {failed: true, message: $e.msg} })
  if not $r.failed or not ($r.message | str contains $bad.1) {
    error make {msg: $"kernel file ($bad.0 | columns | first) was accepted: ($r)"}
  }
}
$env.PKGS_CTX = ($env.PKGS_CTX | upsert spec.env.GOLCONDA_KERNEL_FILES "{}")
# install records the certificates of the built-in keyring
'CONFIG_SYSTEM_TRUSTED_KEYS="certs/golconda-verity.pem"' + "\n" | save --append $"($root)/source/.config"
kbuild build
let flags = (open --raw $"($root)/source/incbin-flags" | lines)
if $flags.0 != $"-DGOLCONDA_INCBIN_SHA256=("test certificate\n" | hash sha256)" {
  error make {msg: $"the certificates' digest is not on system_certificates.o's command line: ($flags)"}
}
rm -rf $"($root)/out/boot"
kbuild install
if (open --raw $"($root)/out/lib/modules/6.18-test/trusted-keys.pem") != "test certificate\n" {
  error make {msg: "install did not record the built-in keys"}
}
"kernelversion:\n\t@exit 7\n" | save -f $"($root)/source/Makefile"
let bad_version = (try { kbuild install; false } catch { true })
if not $bad_version { error make {msg: "failed kernelversion was accepted"} }
cd $pwd
rm -rf $root
print "kernel: install, debug output, config types, fragment precedence, extra config, files, built-in keys, incbin digests, conflict and lost-option rejection pass"
