# uki.nu: ukify build (lib/image/uki.nix).
#
# Structured attrs: fileName, kernel, systemd, stub, initrd, roothash, osRelease,
# cmdlineTemplate, phases (the phase paths to sign, a list), sbKey, sbCert, pcrKey,
# pcrPublicKey.

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

  let uki = $"($out)/($a.fileName)"
  # --phases takes a comma-separated list of phase paths. Each is one colon chain; a
  # signature for a chain permits only that chain's last state.
  let phases = ($a.phases | str join ",")

  # --sign-kernel: the kernel is unsigned; said so because systemd-sbsign cannot check (ukify)
  ^ukify build --linux $linux --initrd $a.initrd --cmdline $cmdline --os-release $"@($a.osRelease)" --uname $uname --stub $a.stub --tools $"($a.systemd)/lib/systemd" --signtool systemd-sbsign --sign-kernel --secureboot-private-key $a.sbKey --secureboot-certificate $a.sbCert --pcr-private-key $a.pcrKey --pcr-public-key $a.pcrPublicKey --phases $phases --pcr-banks sha256 --measure --output $uki
  log $"($a.fileName): (ls $uki | get size.0)"

  check-pcrsig $uki $a.phases
}

# check-pcrsig UKI PHASES: the .pcrsig section must hold one signature for each phase path,
# over the PCR 11 policy digest of that path. Checks the section, not the command line: a
# single colon chain is one path, so --phases with four words and no commas signs only the
# last state. The measured sections are extracted from the UKI, so systemd-measure sees the
# same bytes ukify signed, and its policy-digest must match the section's pol values.
export def check-pcrsig [uki: string, phases: list] {
  let tdir = (mktemp -d -t "golconda-uki-XXXXXX")
  let parts = [linux initrd cmdline osrel uname sbat pcrpkey]
  # the sections systemd-measure measures (ukify adds .pcrpkey, .sbat and the rest with
  # measure=true), by the names systemd-measure takes
  ^ukify inspect $uki --json=off ...($parts | each {|p| $"--section=.($p):binary@($tdir)/($p)" }) --section=$".pcrsig:binary@($tdir)/pcrsig" | ignore

  let signed = (open --raw $"($tdir)/pcrsig" | from json | get sha256 | get pol | sort)
  let expected = (^systemd-measure policy-digest --bank=sha256
      --linux $"($tdir)/linux" --initrd $"($tdir)/initrd" --cmdline $"($tdir)/cmdline"
      --osrel $"($tdir)/osrel" --uname $"($tdir)/uname" --sbat $"($tdir)/sbat"
      --pcrpkey $"($tdir)/pcrpkey" --public-key $"($tdir)/pcrpkey"
      ...($phases | each {|p| $"--phase=($p)" })
    | from json | get sha256 | get pol | sort)

  if $signed != $expected {
    error make { msg: $"($uki | path basename): .pcrsig signs ($signed | length) phase path(s), not the ($phases | length) in image/uki.nix: ($phases | str join ', ')" }
  }
  log $"pcrsig: ($signed | length) signatures, one per phase path: ($phases | str join ', ')"
}
