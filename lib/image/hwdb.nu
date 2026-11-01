# hwdb.nu: compile the selected hwdb.d files into hwdb.bin (lib/image/hwdb.nix).
#
# systemd-hwdb --root=<dir> --usr update reads <dir>/usr/lib/udev/hwdb.d and writes
# <dir>/usr/lib/udev/hwdb.bin. A file in `files` that the sources lack fails the build, so a
# systemd update that renames one is noticed.

use common.nu *

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  let root = $"($env.TMPDIR? | default /tmp)/hwdb-root"
  let src = $"($root)/usr/lib/udev/hwdb.d"
  mkdir $src
  for f in $a.files {
    let p = $"($a.sources)/($f)"
    if not ($p | path exists) {
      error make {msg: $"($f) is not in ($a.sources)"}
    }
    ^cp $p $src
  }
  ^systemd-hwdb $"--root=($root)" --usr update
  mkdir $out
  ^cp $"($root)/usr/lib/udev/hwdb.bin" $"($out)/hwdb.bin"
  log $"hwdb.bin: ($a.files | length) files, (ls $"($out)/hwdb.bin" | get size.0)"
}
