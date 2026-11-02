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
  spec: {env: {GOLCONDA_KERNEL_CONFIG: "{}", GOLCONDA_KERNEL_FRAGMENTS: "[]", GOLCONDA_KERNEL_MAKE: "[]"}}
  out: $"($root)/out", dest: $"($root)/out", deps: [], roots: [], njobs: 1,
  src: $"($root)/source", build: $"($root)/build",
  platform: {cpu: x86_64, names: {kernel: x86}}, testsRun: false, cache: false
}
cd $"($root)/source"
kbuild install
if not ($"($root)/out/lib/modules/6.18-test/vmlinuz" | path exists) { error make {msg: "kernel image missing"} }
if not ($"($root)/debug/lib/debug/vmlinux" | path exists) { error make {msg: "debug vmlinux missing"} }
if (open --raw $"($root)/debug/lib/debug/vmlinux") != "unstripped kernel\n" { error make {msg: "debug vmlinux changed"} }
mkdir $"($root)/source/scripts/kconfig"
cp ($FIXTURES | path join Makefile) $"($root)/source/Makefile" --force
cp ($FIXTURES | path join merge_config.sh) $"($root)/source/scripts/kconfig/merge_config.sh"
let config = {BASE: y, NUMBER: 42, TEXT: 'a"b', OFF: n}
$env.PKGS_CTX = ($env.PKGS_CTX | upsert spec.env.GOLCONDA_KERNEL_CONFIG ($config | to json))
kbuild configure
kbuild build
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
"kernelversion:\n\t@exit 7\n" | save -f $"($root)/source/Makefile"
let bad_version = (try { kbuild install; false } catch { true })
if not $bad_version { error make {msg: "failed kernelversion was accepted"} }
cd $pwd
rm -rf $root
print "kernel: install, debug output, config types, fragment precedence and lost-option rejection pass"
