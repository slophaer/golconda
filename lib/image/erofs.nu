# erofs.nu: mkfs.erofs over the /usr tree, a step of the signer (lib/image/sign.nu).
#
# The parameters come from the manifest's `erofs` (lib/image/erofs.nix erofsParams).

use common.nu *

# make TREE FILE PARAMS: the erofs image of TREE at FILE. -T is both the build time and every
# file's mtime (--all-time is the default); --all-root: the files belong to whoever ran the copy;
# --hard-dereference: an optimised store hardlinks equal files, and the image must not depend on
# whether the build host's store did
export def make [tree: string, file: string, p: record] {
  log $"mkfs.erofs -z($p.compression) -T ($p.epoch) over ($tree)"
  ^mkfs.erofs --quiet $"-z($p.compression)" -T $p.epoch -U $p.uuid --all-root --hard-dereference ...$p.extraArgs $file $tree
  log $"($file | path basename): (ls $file | get size.0)"
}
