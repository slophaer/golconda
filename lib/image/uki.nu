# uki.nu: ukify build (lib/image/uki.nix).
#
# Structured attrs: fileName, kernel, systemd, stub, initrd, roothash, roothashSig, osRelease,
# cmdlineTemplate, phases (the phase paths to sign, a list), sbKey, sbCert, pcrKey,
# pcrPublicKey.

use common.nu *
use initrd.nu [rdinit]

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  $env.LD_LIBRARY_PATH = $a.LD_LIBRARY_PATH
  $env.OPENSSL_CONF = "/dev/null" # no /etc/ssl/openssl.cnf in the sandbox
  mkdir $out

  # the kernel package: lib/modules/<uname>/vmlinuz
  let moddir = (ls $"($a.kernel)/lib/modules" | get name | first)
  let uname = ($moddir | path basename)
  let linux = $"($moddir)/vmlinuz"
  let roothash = (open --raw $a.roothash | str trim)
  let usrhash_sig = (roothash-signature $a.roothashSig $roothash $a.sbCert)
  let cmdline = ($"($a.cmdlineTemplate) rdinit=(rdinit)"
    | str replace "{usrhash}" $roothash | str replace "{usrhashSig}" $usrhash_sig
    | str replace -ra ' +' ' ')
  # the EFI stub cuts a longer cmdline at COMMAND_LINE_SIZE (2048 on x86-64 and arm64) without a
  # word, and the cut lands on the parameters after the signature
  let cmdline_bytes = ($cmdline | encode utf-8 | bytes length)
  if $cmdline_bytes >= 2048 {
    error make { msg: $"cmdline is ($cmdline_bytes) bytes; the kernel keeps 2047" }
  }
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

# roothash-signature PARTITION ROOTHASH CERT: the base64 signature from the usr-verity-sig
# partition (lib/image/verity.nu's JSON, NUL-padded), checked here against the root hash and
# CERT. The kernel checks it against the platform keyring, which holds the firmware db only; a
# signature by another key makes systemd-veritysetup retry unsigned and log at info level, and
# boot goes on, so a mismatch fails the build instead.
export def roothash-signature [partition: string, roothash: string, cert: string] {
  let sig = (open --raw $partition | decode utf-8 | str replace -ra '\x00+$' '' | from json)
  if $sig.rootHash != $roothash {
    error make { msg: $"($partition | path basename) signs ($sig.rootHash), not ($roothash)" }
  }
  let tdir = (mktemp -d -t "golconda-sig-XXXXXX")
  $sig.signature | decode base64 | save -f $"($tdir)/sig.der"
  $roothash | save -f $"($tdir)/roothash"
  let r = (do { ^openssl cms -verify -binary -inform DER -in $"($tdir)/sig.der" -content $"($tdir)/roothash" -certfile $cert -CAfile $cert -purpose any -out /dev/null } | complete)
  if $r.exit_code != 0 {
    error make { msg: $"the root hash signature does not verify against ($cert | path basename), the key the kernel trusts: ($r.stderr | str trim)" }
  }
  log $"root hash signature: verifies against ($cert | path basename)"
  $sig.signature
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
