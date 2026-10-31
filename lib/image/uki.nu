# uki.nu: ukify build (lib/image/uki.nix).
#
# Structured attrs: fileName, kernel, systemd, stub, initrd, roothash, osRelease,
# cmdlineTemplate, phases, sbKey, sbCert, pcrKey, pcrPublicKey.

use common.nu *
use initrd.nu [rdinit]

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  $env.LD_LIBRARY_PATH = $a.LD_LIBRARY_PATH
  mkdir $out

  # the kernel package: lib/modules/<uname>/vmlinuz
  let moddir = (ls $"($a.kernel)/lib/modules" | get name | first)
  let uname = ($moddir | path basename)
  let linux = $"($moddir)/vmlinuz"
  let roothash = (open --raw $a.roothash | str trim)
  # {dlopenPath}: the store directories behind the tree's /usr/lib/<soname> links that PID 1
  # itself opens, by their real paths (a library opened through a symlink gets the symlink's
  # $ORIGIN and loses its own dependencies). The smoke's cmdlineExtra puts this in
  # LD_LIBRARY_PATH until the fork's RUNPATH names the dlopen directories; services get theirs
  # from /base's system.conf.d. The cmdline is limited to about 1 KiB, so PID 1's set only.
  let pid1_sonames = [libmount.so.1 libblkid.so.1 libseccomp.so.2 libacl.so.1 libpam.so.0 libcrypto.so.3 libtss2-esys.so.0]
  let dlopen_path = (ls -l $"($a.usrTree)/lib" | where type == symlink and ($it.name | path basename) in $pid1_sonames | get target
    | each {|t| $"/usr/($t | str replace -r '^\.\./' '')" | path dirname } | uniq | sort | str join ":")
  let cmdline = ($"($a.cmdlineTemplate) rdinit=(rdinit $a.systemd)"
    | str replace "{usrhash}" $roothash | str replace -a "{dlopenPath}" $dlopen_path | str replace -ra ' +' ' ')
  $cmdline | save -f $"($out)/cmdline"
  log $"kernel ($uname), cmdline: ($cmdline)"

  # --sign-kernel: the kernel is unsigned; said so because systemd-sbsign cannot check (ukify)
  ^ukify build --linux $linux --initrd $a.initrd --cmdline $cmdline --os-release $"@($a.osRelease)" --uname $uname --stub $a.stub --tools $"($a.systemd)/lib/systemd" --signtool systemd-sbsign --sign-kernel --secureboot-private-key $a.sbKey --secureboot-certificate $a.sbCert --pcr-private-key $a.pcrKey --pcr-public-key $a.pcrPublicKey --phases $a.phases --pcr-banks sha256 --measure --output $"($out)/($a.fileName)"
  log $"($a.fileName): (ls $"($out)/($a.fileName)" | get size.0)"
}
