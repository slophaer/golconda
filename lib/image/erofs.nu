# erofs.nu: mkfs.erofs over the /usr tree (lib/image/erofs.nix).
#
# Structured attrs: usrTree, epoch, fileName, uuid, compression, extraArgs.

use common.nu *

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  mkdir $out
  log $"mkfs.erofs -z($a.compression) -T ($a.epoch) over ($a.usrTree)"
  # -T is both the build time and every file's mtime (--all-time is the default)
  ^mkfs.erofs $"-z($a.compression)" -T $a.epoch -U $a.uuid --all-root ...$a.extraArgs $"($out)/($a.fileName)" $a.usrTree
  let size = (ls $"($out)/($a.fileName)" | get size.0)
  log $"($a.fileName): ($size)"
}
