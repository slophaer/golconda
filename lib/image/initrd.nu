# initrd.nu: the zstd cpio around the initrd's /usr tree (lib/image/initrd.nix).
#
# Structured attrs: usrTree, dmRules.

use common.nu *

# The path rdinit= names: /init, the link to systemd (initrd.nix says why it can be a link)
export def rdinit []: nothing -> string {
  "/init"
}

# renumber: a Python program (the seed's python3) that rewrites the newc headers of the cpio
# it is given, in place. bsdtar copies each file's inode number, device and link count from the
# build directory, and libarchive has no option to set them (its mtree reader takes them from
# the file on disk too), so two builds of the same tree gave different bytes. The program numbers
# the entries 1, 2, ... in the archive's (sorted) order, one number for each (device, inode) of
# the build directory, so hard links keep their group; sets devmajor and devminor to 0; and
# gives a directory 2 + its subdirectories as nlink (the file system's count differs: btrfs says
# 1). The kernel links two entries only for the same inode and device with nlink >= 2.
export def renumber []: nothing -> string {
  r#'
import mmap, sys
from collections import Counter

INO, MODE, NLINK, SIZE, DEVMAJOR, DEVMINOR, NAMESIZE = 0, 1, 4, 6, 7, 8, 11
with open(sys.argv[1], "r+b") as f, mmap.mmap(f.fileno(), 0) as m:
    def get(off, i):
        return int(m[off + 6 + 8 * i : off + 14 + 8 * i], 16)

    def put(off, i, v):
        m[off + 6 + 8 * i : off + 14 + 8 * i] = b"%08X" % v

    entries, inos, subdirs, off = [], {}, Counter(), 0
    while True:
        if m[off : off + 6] != b"070701":
            sys.exit(f"renumber: no newc header at {off}")
        namesize, size = get(off, NAMESIZE), get(off, SIZE)
        name = m[off + 110 : off + 109 + namesize]
        if name == b"TRAILER!!!":
            break
        isdir = get(off, MODE) & 0o170000 == 0o040000
        if isdir:
            subdirs[name.rpartition(b"/")[0]] += 1
        key = (get(off, DEVMAJOR), get(off, DEVMINOR), get(off, INO))
        entries.append((off, name, isdir, inos.setdefault(key, len(inos) + 1)))
        off = (off + 110 + namesize + 3) & ~3
        off = (off + size + 3) & ~3
    for off, name, isdir, ino in entries:
        put(off, INO, ino)
        put(off, DEVMAJOR, 0)
        put(off, DEVMINOR, 0)
        if isdir:
            put(off, NLINK, 2 + subdirs[name])
'#
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

  # newc cpio, root-owned, one mtime, sorted names; then the fields bsdtar takes from the build
  # directory, fixed (renumber): reproducible
  cd $root
  let list = $"($env.NIX_BUILD_TOP)/list"
  ^find . -mindepth 1 | lines | str replace -r '^\./' '' | sort | save -f $list
  log $"(open --raw $list | lines | length) entries"
  let cpio = $"($env.NIX_BUILD_TOP)/initrd.cpio"
  ^bsdtar -cf $cpio --format newc --uid 0 --gid 0 --uname root --gname root --mtime "1970-01-01 00:00:01 UTC" -n -T $list
  ^python3 -c (renumber) $cpio
  ^zstd -q -19 -T1 --rm -o $"($out)/initrd.cpio.zst" $"($env.NIX_BUILD_TOP)/initrd.cpio"
  $init | save -f $"($out)/rdinit"
  log $"initrd.cpio.zst: (ls $"($out)/initrd.cpio.zst" | get size.0), rdinit=($init)"
}
