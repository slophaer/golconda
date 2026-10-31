# erofs.nu: mkfs.erofs over the /usr tree (lib/image/erofs.nix).
#
# Structured attrs: usrTree, epoch, fileName, uuid, compression, extraArgs,
# PROTOTYPE: rootSkeleton (bool), pcrPublicKey (path).

use common.nu *

# PROTOTYPE (no initrd): the image is the whole root file system. /usr is the tree; around it the
# mount points, the merged-/usr links, and an /etc made at build time by the same tmpfiles and
# sysusers lines the machine would run.
def root-skeleton [a: record]: nothing -> string {
  let root = $"($env.NIX_BUILD_TOP)/root"
  mkdir $root
  ^cp -a $a.usrTree $"($root)/usr"
  ^chmod -R u+w $root
  for d in [etc var run proc sys dev tmp home root efi] { mkdir $"($root)/($d)" }
  ^ln -s usr/bin $"($root)/bin"
  ^ln -s usr/bin $"($root)/sbin"
  ^ln -s usr/lib $"($root)/lib"
  # PID 1 bind-mounts a transient machine-id over this empty file (the file must exist)
  touch $"($root)/etc/machine-id"

  # the PCR policy public key: systemd-stub passes it only through an initrd
  ^cp $a.pcrPublicKey $"($root)/usr/lib/systemd/tpm2-pcr-public-key.pem"
  # the PCR signature of the booted UKI, from the ESP; the state directory for the credstore
  [
    "# PROTOTYPE (no initrd): what systemd-stub would pass in /.extra"
    "C /run/systemd/tpm2-pcr-signature.json 0444 root root - /efi/loader/golconda/%A.pcrsig.json"
  ] | str join "\n" | save -f $"($root)/usr/lib/tmpfiles.d/golconda-noinitrd.conf"
  # /etc at build time: passwd/group/shadow from sysusers.d, links and copies from tmpfiles.d.
  # The copy is the seed for the state partition: systemd-repart's CopyFiles= puts it at
  # /etc there, and the state partition is mounted, so /etc is writable without an overlay.
  ^systemd-sysusers $"--root=($root)"
  ^systemd-tmpfiles $"--root=($root)" --create --boot --prefix=/etc
  mkdir $"($root)/usr/lib/golconda"
  ^cp -a $"($root)/etc" $"($root)/usr/lib/golconda/state-etc"
  log "/etc:"
  ^find $"($root)/etc" -maxdepth 2 | lines | each {|l| log $"  ($l | str replace $root '')" } | ignore
  $root
}

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  $env.LD_LIBRARY_PATH = ($a.LD_LIBRARY_PATH? | default "")
  mkdir $out
  let src = if ($a.rootSkeleton? | default false) { root-skeleton $a } else { $a.usrTree }
  log $"mkfs.erofs -z($a.compression) -T ($a.epoch) over ($src)"
  # -T is both the build time and every file's mtime (--all-time is the default)
  ^mkfs.erofs $"-z($a.compression)" -T $a.epoch -U $a.uuid --all-root ...$a.extraArgs $"($out)/($a.fileName)" $src
  let size = (ls $"($out)/($a.fileName)" | get size.0)
  log $"($a.fileName): ($size)"
}
