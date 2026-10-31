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
  for f in (ls $"($a.dmRules)/*.rules" | get name) {
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

  # newc cpio, root-owned, one mtime, sorted names: reproducible
  cd $root
  let list = $"($env.NIX_BUILD_TOP)/list"
  ^find . -mindepth 1 | lines | str replace -r '^\./' '' | sort | save -f $list
  log $"(open --raw $list | lines | length) entries"
  ^bsdtar -cf $"($env.NIX_BUILD_TOP)/initrd.cpio" --format newc --uid 0 --gid 0 --uname root --gname root --mtime "1970-01-01 00:00:01 UTC" -n -T $list
  ^zstd -q -19 -T1 --rm -o $"($out)/initrd.cpio.zst" $"($env.NIX_BUILD_TOP)/initrd.cpio"
  $init | save -f $"($out)/rdinit"
  log $"initrd.cpio.zst: (ls $"($out)/initrd.cpio.zst" | get size.0), rdinit=($init)"
}
