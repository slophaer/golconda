# Golconda's kernel phases, loaded through repkgs' package-local module interface.
# shortcut: x86_64 only; add an architecture config and boot proof before another target.
use core.nu *

# Keep build data in structured attributes, not generated Nushell source.
def kernel-options []: nothing -> record {
  let values = (ctx).spec.env
  {
    config: ($values.GOLCONDA_KERNEL_CONFIG | from json)
    fragments: ($values.GOLCONDA_KERNEL_FRAGMENTS | from json)
    make: ($values.GOLCONDA_KERNEL_MAKE | from json)
  }
}

def make-flags []: nothing -> list<string> {
  [ARCH=x86 $"-j((ctx).njobs)" LLVM=1 LLVM_IAS=1] ++ (kernel-options).make
}

def config-line [name: string, value: any]: nothing -> string {
  if $value == "n" { return $"# CONFIG_($name) is not set" }
  let v = if $value == "y" or $value == "m" or ($value | describe) == int {
    $value | into string
  } else { $value | to json --raw }
  $"CONFIG_($name)=($v)"
}

def verify-config [config: record, dotconfig: string]: nothing -> nothing {
  let final = (open --raw $dotconfig | lines)
  let errors = ($config | items {|name, value|
    let want = (config-line $name $value)
    let alt = if $value == "n" { $"CONFIG_($name)=n" } else { null }
    if not (($want in $final) or ($alt != null and $alt in $final)) {
      $"CONFIG_($name): wanted ($value), not found in .config"
    }
  } | compact)
  if ($errors | is-not-empty) { error make {msg: $"kernel config verification failed:\n($errors | str join '\n')"} }
  note kbuild-verify $"($config | columns | length) options verified"
}

def fragment-lines [files: list<string>]: nothing -> list<string> {
  $files | each {|f|
    open --raw $f | lines | str trim
      | where { $in =~ '^CONFIG_[A-Za-z0-9_]+=' or $in =~ '^# CONFIG_[A-Za-z0-9_]+ is not set$' }
  } | flatten
}

def fragment-name [line: string]: nothing -> string {
  $line | parse -r '^(?:# )?CONFIG_([A-Za-z0-9_]+)' | get 0.capture0
}

def verify-fragments [lines: list<string>, dotconfig: string]: nothing -> nothing {
  let final = (open --raw $dotconfig | lines)
  let last = ($lines | reduce -f {} {|l, acc| $acc | upsert (fragment-name $l) $l } | values)
  let errors = ($last | each {|l|
    let alt = if ($l | str starts-with "# ") { $"CONFIG_(fragment-name $l)=n" } else { null }
    if not (($l in $final) or ($alt != null and $alt in $final)) { $"($l): not found in .config" }
  } | compact)
  if ($errors | is-not-empty) { error make {msg: $"kernel fragment verification failed:\n($errors | str join '\n')"} }
  note kbuild-verify $"($last | length) fragment options verified"
}

export def configure []: nothing -> nothing {
  let c = (ctx)
  let o = (kernel-options)
  cd $c.src
  x make ...(make-flags) defconfig
  let fragments = $o.fragments
  let overridden = (fragment-lines $fragments | each {|l| fragment-name $l } | uniq)
  let typed_file = $"($c.build)/kernel.config"
  if ($o.config | is-not-empty) {
    ($o.config | items {|name, value| config-line $name $value } | str join "\n") + "\n" | save -f $typed_file
  }
  let files = ((if ($o.config | is-not-empty) { [$typed_file] } else { [] }) ++ $fragments)
  if ($files | is-not-empty) {
    x sh $"($c.src)/scripts/kconfig/merge_config.sh" -m $"($c.src)/.config" ...$files
    x make ...(make-flags) olddefconfig
    let typed = ($o.config | columns | where { $in not-in $overridden } | reduce -f {} {|n, acc| $acc | insert $n ($o.config | get $n) })
    if ($typed | is-not-empty) { verify-config $typed $"($c.src)/.config" }
    if ($fragments | is-not-empty) { verify-fragments (fragment-lines $fragments) $"($c.src)/.config" }
  }
}

export def build []: nothing -> nothing {
  cd (ctx).src
  x make ...(make-flags) bzImage
}

export def install []: nothing -> nothing {
  let c = (ctx)
  cd $c.src
  let result = (x make ...(make-flags) -s kernelversion | complete)
  if $result.exit_code != 0 { error make {msg: $"kernelversion failed: ($result.stderr)"} }
  let version = ($result.stdout | str trim)
  if ($version | is-empty) { error make {msg: "kernelversion returned an empty version"} }
  let moddir = $"($c.out)/lib/modules/($version)"
  mkdir $moddir
  cp $"($c.src)/arch/x86/boot/bzImage" $"($moddir)/vmlinuz"
  cp $"($c.src)/System.map" $"($moddir)/System.map"
  cp $"($c.src)/.config" $"($moddir)/config"
  mkdir $"($c.out)/boot"
  ^ln -s $"../lib/modules/($version)/vmlinuz" $"($c.out)/boot/vmlinuz-($version)"
  let debug = ((attrs).outputs.debug? | default "")
  if ($debug | is-not-empty) {
    mkdir $"($debug)/lib/debug"
    cp $"($c.src)/vmlinux" $"($debug)/lib/debug/vmlinux"
  }
  note kbuild-install $"lib/modules/($version)/vmlinuz System.map config"
}
