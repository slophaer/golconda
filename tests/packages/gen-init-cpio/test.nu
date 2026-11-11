# gen-init-cpio: the cpio it writes depends only on the entry list and the files' contents.
# Two runs over copies of the same files (other inodes, other mtimes, other directory) give the
# same bytes with -t; without -t a file's own mtime goes in, so they differ. The headers carry
# the counters the package says (inode from 721, device 3:1, nlink), a hard link is one inode
# with the data on its last name, and bsdtar reads the archive back with the modes, owners and
# link target of the list.
use checks.nu *
let gic = $"($env.pkg)/bin/gen_init_cpio"
let tmp = $"($env.TMPDIR? | default /tmp)/gic"
rm -rf $tmp
mkdir $tmp

# the same two files in two places, with other inodes and mtimes
def files [dir: string, stamp: string] {
  mkdir $dir
  "hello\n" | save $"($dir)/f"
  "#!/bin/sh\n" | save $"($dir)/x"
  ^touch -d $stamp $"($dir)/f" $"($dir)/x"
}
files $"($tmp)/a" "2001-01-01 00:00:00"
files $"($tmp)/b" "2002-02-02 00:00:00"

def list [src: string]: nothing -> string {
  [
    "# a comment"
    "dir /usr 0755 0 0"
    $"file /usr/f ($src)/f 0644 0 0 /usr/g"
    $"file /usr/x ($src)/x 4755 0 0"
    "slink /usr/l f 0777 0 0"
    "dir /dev 0755 0 0"
    "nod /dev/console 0600 0 5 c 5 1"
  ] | str join "\n"
}
list $"($tmp)/a" | save $"($tmp)/a.list"
list $"($tmp)/b" | save $"($tmp)/b.list"

def raw [f: string]: nothing -> binary { open --raw $f | into binary }
def --wrapped gic [...args: string] {
  let r = (^$gic ...$args | complete)
  assert $"gen_init_cpio ($args | str join ' ') exits 0: ($r.stderr)" ($r.exit_code == 0)
}
gic -t 1 -o $"($tmp)/a.cpio" $"($tmp)/a.list"
gic -t 1 -o $"($tmp)/b.cpio" $"($tmp)/b.list"
let a = (raw $"($tmp)/a.cpio")
assert "with -t, two runs over copies of the files are the same bytes" ($a == (raw $"($tmp)/b.cpio"))
gic -o $"($tmp)/a0.cpio" $"($tmp)/a.list"
gic -o $"($tmp)/b0.cpio" $"($tmp)/b.list"
assert "without -t, the files' own mtimes make them differ" ((raw $"($tmp)/a0.cpio") != (raw $"($tmp)/b0.cpio"))

# the newc headers, in archive order: name and the 13 hex fields
const FIELDS = [ino mode uid gid nlink mtime filesize devmajor devminor rdevmajor rdevminor namesize check]
def entries [data: binary]: nothing -> list<record> {
  mut off = 0
  mut out = []
  loop {
    let head = ($data | bytes at $off..<($off + 110) | decode)
    if not ($head starts-with "070701") { error make {msg: $"no newc header at ($off)"} }
    let h = ($FIELDS | enumerate | each {|f| {($f.item): ($head | str substring (6 + 8 * $f.index)..<(14 + 8 * $f.index) | into int --radix 16)} } | into record)
    let name = ($data | bytes at ($off + 110)..<($off + 109 + $h.namesize) | decode)
    $off = (($off + 110 + $h.namesize + 3) | bits and (-4))
    let body = ($data | bytes at $off..<($off + $h.filesize))
    $off = (($off + $h.filesize + 3) | bits and (-4))
    if $name == "TRAILER!!!" { break }
    $out = ($out | append ($h | insert name $name | insert body $body))
  }
  $out
}
let e = (entries $a)
assert $"the entries in list order, without the leading /: ($e.name)" ($e.name == [usr usr/f usr/g usr/x usr/l dev dev/console])
assert $"inode numbers from 721, one for both names of the hard link: ($e.ino)" ($e.ino == [721 722 722 723 724 725 726])
assert "every mtime is -t's" ($e.mtime | all {|t| $t == 1 })
assert "every device is 3:1" ($e | all {|x| $x.devmajor == 3 and $x.devminor == 1 })
assert $"nlink: 2 for a directory, 2 for the hard link, 1 else: ($e.nlink)" ($e.nlink == [2 2 2 1 1 2 1])
assert "the hard link's data is on its last name only" (($e.1.filesize == 0) and ($e.2.body == ("hello\n" | into binary)))
assert "the symlink's data is its target" (($e.4.body | decode) == "f\u{0}")
assert $"the modes with their type bits: ($e.mode)" ($e.mode == [0o40755 0o100644 0o100644 0o104755 0o120777 0o40755 0o20600])
assert "the device node's numbers and owner" (($e.6.rdevmajor == 5) and ($e.6.rdevminor == 1) and ($e.6.gid == 5))

# bsdtar reads it back: modes, owners, the link target, the contents
let listing = (^bsdtar -tvf $"($tmp)/a.cpio" | lines)
assert $"bsdtar lists every entry: ($listing)" (($listing | length) == 7)
assert "bsdtar sees the setuid file owned by root" ($listing | any {|l| $l =~ '^-rwsr-xr-x .* 0 +0 .* usr/x$' })
assert "bsdtar sees the symlink" ($listing | any {|l| $l =~ '^lrwxrwxrwx .* usr/l -> f$' })
mkdir $"($tmp)/out"
^bsdtar -xf $"($tmp)/a.cpio" -C $"($tmp)/out" --exclude dev/console
assert "both names of the hard link hold the data" (((raw $"($tmp)/out/usr/f") == ("hello\n" | into binary)) and ((raw $"($tmp)/out/usr/g") == ("hello\n" | into binary)))

# a list it cannot read fails the run
"file /usr/missing /nonexistent 0644 0 0" | save $"($tmp)/bad.list"
let bad = (^$gic -t 1 -o $"($tmp)/bad.cpio" $"($tmp)/bad.list" | complete)
assert "a file it cannot open fails the run" ($bad.exit_code != 0)
done
