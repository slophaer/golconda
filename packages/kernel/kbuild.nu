# Golconda's kernel phases, loaded through repkgs' package-local module interface.
# shortcut: x86_64 only; add an architecture config and boot proof before another target.
use core.nu *

# Keep build data in structured attributes, not generated Nushell source.
# config: the package's typed base. extra: typed options the system requires (nix/packages.nix),
# merged over the base and never overridden by a fragment
def kernel-options []: nothing -> record {
  let values = (ctx).spec.env
  {
    config: ($values.GOLCONDA_KERNEL_CONFIG | from json)
    extra: ($values.GOLCONDA_KERNEL_EXTRA_CONFIG | from json)
    fragments: ($values.GOLCONDA_KERNEL_FRAGMENTS | from json)
    files: ($values.GOLCONDA_KERNEL_FILES | from json)
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

# Copy the system's files into the tree at the paths the config names (the verity certificate
# at SYSTEM_TRUSTED_KEYS): the config stays the same when a file changes, so only the objects
# that read the file recompile. A path must stay inside the tree and must not replace a
# kernel file; a missing source fails the copy.
def copy-files [files: record, src: string]: nothing -> nothing {
  # a loop, not items: an error inside a closure loses its message
  for f in ($files | transpose dest from) {
    let dest = $f.dest
    let from = $f.from
    if ($dest | str starts-with "/") or (".." in ($dest | path split)) {
      error make {msg: $"kernel file ($dest): the path must be relative and inside the tree"}
    }
    let to = ($src | path join $dest)
    if ($to | path exists) { error make {msg: $"kernel file ($dest): the tree already has it"} }
    if not ($from | path exists) { error make {msg: $"kernel file ($dest): ($from) does not exist"} }
    mkdir ($to | path dirname)
    cp $from $to
  }
  if ($files | is-not-empty) { note kbuild-files $"($files | columns | str join ' ')" }
}

export def configure []: nothing -> nothing {
  let c = (ctx)
  let o = (kernel-options)
  cd $c.src
  copy-files $o.files $c.src
  x make ...(make-flags) defconfig
  let fragments = $o.fragments
  let overridden = (fragment-lines $fragments | each {|l| fragment-name $l } | uniq)
  let config = ($o.config | merge $o.extra)
  let typed_file = $"($c.build)/kernel.config"
  if ($config | is-not-empty) {
    ($config | items {|name, value| config-line $name $value } | str join "\n") + "\n" | save -f $typed_file
  }
  let files = ((if ($config | is-not-empty) { [$typed_file] } else { [] }) ++ $fragments)
  if ($files | is-not-empty) {
    x sh $"($c.src)/scripts/kconfig/merge_config.sh" -m $"($c.src)/.config" ...$files
    x make ...(make-flags) olddefconfig
    # a fragment may change a base option; the extra options are checked last, even where a
    # fragment names them, so a contradicting fragment fails the build
    let base = ($o.config | reject -o ...($overridden ++ ($o.extra | columns)))
    if ($base | is-not-empty) { verify-config $base $"($c.src)/.config" }
    if ($fragments | is-not-empty) { verify-fragments (fragment-lines $fragments) $"($c.src)/.config" }
    if ($o.extra | is-not-empty) { verify-config $o.extra $"($c.src)/.config" }
  }
}

# The file CONFIG_SYSTEM_TRUSTED_KEYS names, or null
def trusted-keys []: nothing -> any {
  let keys = (open --raw $"((ctx).src)/.config" | lines | parse -r '^CONFIG_SYSTEM_TRUSTED_KEYS="(.+)"$')
  if ($keys | is-empty) { null } else { (ctx).src | path join $keys.0.capture0 }
}

# jig keys a cached object on its command line and on the inputs its depfile names, and clang's
# depfile leaves out .incbin files. Two objects .incbin what changes with neither source nor config:
# the built-in certificates (certs/system_certificates.o) and the compressed kernel
# (arch/x86/boot/compressed/piggy.o). The digest of each input goes on the object's command line
# (AFLAGS_<object>, a make variable kbuild reads), so a cached object never carries another
# build's certificate or kernel. jig now refuses to cache a compile that names .incbin; the digests
# stay as a second guard for the trust property (docs/design/trust.md).
def incbin-flag [object: string, file: string]: nothing -> string {
  $"AFLAGS_($object).o=-DGOLCONDA_INCBIN_SHA256=(open --raw $file | hash sha256)"
}

export def build []: nothing -> nothing {
  cd (ctx).src
  let keys = (trusted-keys)
  let certs = if $keys == null { [] } else { [(incbin-flag system_certificates $keys)] }
  x make ...(make-flags) ...$certs vmlinux
  x make ...(make-flags) ...$certs (incbin-flag piggy vmlinux) bzImage
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
  # record the certificates of the built-in keyring: the config names only a path in the tree
  let keys = (trusted-keys)
  if $keys != null { cp $keys $"($moddir)/trusted-keys.pem" }
  mkdir $"($c.out)/boot"
  ^ln -s $"../lib/modules/($version)/vmlinuz" $"($c.out)/boot/vmlinuz-($version)"
  let debug = ((attrs).outputs.debug? | default "")
  if ($debug | is-not-empty) {
    mkdir $"($debug)/lib/debug"
    cp $"($c.src)/vmlinux" $"($debug)/lib/debug/vmlinux"
  }
  note kbuild-install $"lib/modules/($version)/vmlinuz System.map config"
}
