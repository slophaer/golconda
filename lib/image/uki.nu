# uki.nu: ukify build, a step of the signer (lib/image/sign.nu). The parameters come from the
# manifest's `uki` (lib/image/uki.nix ukiParams): fileName, kernel, systemd, stub, initrd,
# osRelease, cmdlineTemplate, phases (the phase paths to sign, a list).

use common.nu *
use initrd.nu [rdinit]

# make P ROOTHASH SIGPART KEYS OUT: the UKI at OUT, its cmdline with ROOTHASH and the signature
# from the usr-verity-sig partition SIGPART, Secure Boot signed with KEYS.dbKey/dbCert
# (systemd-sbsign) and with one PCR 11 signature per phase path by KEYS.pcrKey, KEYS.pcrPublic
# embedded as .pcrpkey. Returns the cmdline.
export def make [p: record, roothash: string, sigpart: string, keys: record, out: string]: nothing -> string {
  # the kernel package: lib/modules/<uname>/vmlinuz
  let moddir = (ls $"($p.kernel)/lib/modules" | get name | first)
  let uname = ($moddir | path basename)
  let linux = $"($moddir)/vmlinuz"
  let usrhash_sig = (roothash-signature $sigpart $roothash $keys.dbCert)
  let cmdline = ($"($p.cmdlineTemplate) rdinit=(rdinit)"
    | str replace "{usrhash}" $roothash | str replace "{usrhashSig}" $usrhash_sig
    | str replace -ra ' +' ' ' | str trim)
  # the EFI stub cuts a longer cmdline at COMMAND_LINE_SIZE (2048 on x86-64 and arm64) without a
  # word, and the cut lands on the parameters after the signature
  let cmdline_bytes = ($cmdline | encode utf-8 | bytes length)
  if $cmdline_bytes >= 2048 {
    error make { msg: $"cmdline is ($cmdline_bytes) bytes; the kernel keeps 2047" }
  }
  log $"kernel ($uname), cmdline: ($cmdline)"

  # --phases takes a comma-separated list of phase paths. Each is one colon chain; a
  # signature for a chain permits only that chain's last state.
  let phases = ($p.phases | str join ",")

  # --sign-kernel: the kernel is unsigned; said so because systemd-sbsign cannot check (ukify)
  ^ukify build --linux $linux --initrd $p.initrd --cmdline $cmdline --os-release $"@($p.osRelease)" --uname $uname --stub $p.stub --tools $"($p.systemd)/lib/systemd" --signtool systemd-sbsign --sign-kernel --secureboot-private-key $keys.dbKey --secureboot-certificate $keys.dbCert --pcr-private-key $keys.pcrKey --pcr-public-key $keys.pcrPublic --phases $phases --pcr-banks sha256 --measure --output $out
  log $"($out | path basename): (ls $out | get size.0)"

  check-pcrsig $out $p.phases
  $cmdline
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
