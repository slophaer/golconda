# uki.nu: ukify build (lib/image/uki.nix).
#
# Structured attrs: fileName, kernel, systemd, stub, initrd, roothash, osRelease,
# cmdlineTemplate, phases, sbKey, sbCert, pcrKey, pcrPublicKey.

use common.nu *
use initrd.nu [rdinit]

# A UUID (8-4-4-4-12) from 32 hex digits
def uuid-of [hex: string]: nothing -> string {
  [($hex | str substring 0..<8) ($hex | str substring 8..<12) ($hex | str substring 12..<16) ($hex | str substring 16..<20) ($hex | str substring 20..<32)] | str join "-"
}

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
  let no_initrd = ($a.noInitrd? | default false)
  let cmdline = if $no_initrd {
    # PROTOTYPE (no initrd): the kernel maps the verity root itself (dm-init) from the two
    # partitions whose UUIDs systemd derives from the root hash, and mounts it as /
    let t = (open $a.verityTable)
    let usr_uuid = (uuid-of ($roothash | str substring 0..<32))
    let verity_uuid = (uuid-of ($roothash | str substring 32..<64))
    let sectors = $t.dataBlocks * $t.dataBlockSize / 512
    let table = $"0 ($sectors) verity 1 PARTUUID=($usr_uuid) PARTUUID=($verity_uuid) ($t.dataBlockSize) ($t.hashBlockSize) ($t.dataBlocks) ($t.hashStart) ($t.algorithm) ($roothash) ($t.salt)"
    let dm = $"dm-mod.create=\"root,,,ro,($table)\" root=/dev/dm-0 rootfstype=erofs ro"
    ($"($a.cmdlineTemplate) init=(rdinit $a.systemd)"
      | str replace "usrhash={usrhash}" $dm | str replace -a "{dlopenPath}" $dlopen_path | str replace -ra ' +' ' ')
  } else {
    ($"($a.cmdlineTemplate) rdinit=(rdinit $a.systemd)"
      | str replace "{usrhash}" $roothash | str replace -a "{dlopenPath}" $dlopen_path | str replace -ra ' +' ' ')
  }
  $cmdline | save -f $"($out)/cmdline"
  log $"kernel ($uname), cmdline: ($cmdline)"

  # --sign-kernel: the kernel is unsigned; said so because systemd-sbsign cannot check (ukify)
  let initrd_args = if $no_initrd { [] } else { [--initrd $a.initrd] }
  ^ukify build --linux $linux ...$initrd_args --cmdline $cmdline --os-release $"@($a.osRelease)" --uname $uname --stub $a.stub --tools $"($a.systemd)/lib/systemd" --signtool systemd-sbsign --sign-kernel --secureboot-private-key $a.sbKey --secureboot-certificate $a.sbCert --pcr-private-key $a.pcrKey --pcr-public-key $a.pcrPublicKey --phases $a.phases --pcr-banks sha256 --measure --output $"($out)/($a.fileName)"
  log $"($a.fileName): (ls $"($out)/($a.fileName)" | get size.0)"
  if $no_initrd {
    # PROTOTYPE: the PCR signature as a file for the ESP (systemd-stub hands it on only in an initrd)
    let raw = $"($env.NIX_BUILD_TOP)/pcrsig.raw"
    ^ukify inspect --section $".pcrsig:binary@($raw)" $"($out)/($a.fileName)" | ignore
    open --raw $raw | decode utf-8 | str replace -a "\u{0}" "" | save -f $"($out)/pcrsig.json"
    log $"pcrsig.json: (open --raw $"($out)/pcrsig.json" | str length) bytes"
  }
}
