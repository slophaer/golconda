# initrd.nu: the zstd cpio around the initrd's /usr tree (lib/image/initrd.nix).
#
# Structured attrs: usrTree, dmRules.

use common.nu *

# The path rdinit= names: /init, the link to systemd (initrd.nix says why it can be a link)
export def rdinit []: nothing -> string {
  "/init"
}

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  let root = $"($env.NIX_BUILD_TOP)/root"
  mkdir $root $out

  log $"copying ($a.usrTree)"
  ^cp -a $a.usrTree $"($root)/usr"
  ^chmod -R u+w $root

  # systemd as PID 1, and how it knows it is in an initrd
  ^ln -s usr/lib/systemd/systemd $"($root)/init"
  mkdir $"($root)/etc"
  ^ln -s ../usr/lib/os-release $"($root)/etc/initrd-release"
  ^ln -s initrd-release $"($root)/etc/os-release"
  # merged /usr
  ^ln -s usr/bin $"($root)/bin"
  ^ln -s usr/bin $"($root)/sbin"
  ^ln -s usr/lib $"($root)/lib"
  for d in [proc sys dev run tmp var sysroot] { mkdir $"($root)/($d)" }

  # lvm2's device-mapper rules call dmsetup by absolute path: {prefix} is /usr here
  let rules = $"($root)/usr/lib/udev/rules.d"
  mkdir $rules
  for f in (ls ($"($a.dmRules)/*.rules" | into glob) | get name) {
    let dest = $"($rules)/($f | path basename)"
    if ($dest | path exists -n) { error make {msg: $"($dest) exists: two sources for a dm rule"} }
    open --raw $f | str replace -a "{prefix}" "/usr" | save -f $dest
    log $"dm rule ($f | path basename)"
  }

  # what the kernel execs (rdinit=) must lead to a real file in the cpio, through its links
  let init = (rdinit)
  if ($"($root)($init)" | path expand | path type) != file { error make {msg: $"($init) does not lead to a file in the initrd"} }
  for p in [/usr/lib/systemd/systemd /usr/lib/systemd/systemd-executor /usr/lib/systemd/systemd-udevd /usr/lib/systemd/systemd-veritysetup /usr/lib/systemd/system-generators/systemd-veritysetup-generator /usr/lib/systemd/system-generators/systemd-gpt-auto-generator /usr/bin/dmsetup /usr/bin/systemctl] {
    if not ($"($root)($p)" | path exists) { error make {msg: $"($p) missing from the initrd"} }
  }

  # newc cpio by gen_init_cpio (packages/gen-init-cpio), from a list of the entries sorted by
  # name: root-owned, the mode from the build directory, a symlink with its target, every mtime 1
  # (-t). It numbers the inodes itself and writes fixed devices and link counts, so nothing of
  # the build directory but the names, modes, targets and contents reaches the archive:
  # reproducible. A file is one entry with its own data (no hard links: the initrd has none). The
  # list splits at whitespace and expands ${VAR} in a file's location: a name or target with
  # either, or another file type, fails here
  cd $root
  let entries = (^find . -mindepth 1 -printf "%M\t%m\t%P\t%l\n" | lines | split column "\t" type mode name target | sort-by name)
  let spec = ($entries | each {|e|
    if ($"($e.name)($e.target)" =~ '\s|\$') { error make {msg: $"($e.name): a name or link target with whitespace or a dollar sign, which gen_init_cpio cannot take"} }
    match ($e.type | str substring 0..0) {
      "d" => $"dir /($e.name) ($e.mode) 0 0"
      "-" => $"file /($e.name) ($root)/($e.name) ($e.mode) 0 0"
      "l" => $"slink /($e.name) ($e.target) ($e.mode) 0 0"
      _ => { error make {msg: $"($e.name): ($e.type) is no file, directory or symlink"} }
    }
  })
  let list = $"($env.NIX_BUILD_TOP)/list"
  $spec | each {|l| $"($l)\n" } | str join | save -f $list
  log $"($spec | length) entries"
  let cpio = $"($env.NIX_BUILD_TOP)/initrd.cpio"
  ^gen_init_cpio -t 1 -o $cpio $list
  ^zstd -q -19 -T1 --rm -o $"($out)/initrd.cpio.zst" $"($env.NIX_BUILD_TOP)/initrd.cpio"
  $init | save -f $"($out)/rdinit"
  log $"initrd.cpio.zst: (ls $"($out)/initrd.cpio.zst" | get size.0), rdinit=($init)"
}
