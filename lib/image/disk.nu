# disk.nu: systemd-repart over the rendered definitions (lib/image/disk.nix).
#
# Structured attrs: definitions (name -> INI text with {esp} {usr} {verity} {sig} {usrUuid}
# {verityUuid}), usr, verity, sig, roothash, uki, ukiName, systemdBoot, bootEntry,
# architecture, seed, epoch, loaderConf, sbKey, sbCert.

use common.nu *

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

  # the ESP's content: the signed systemd-boot on the removable-media path, its policy, the UKI
  # where it looks
  let esp = $"($env.NIX_BUILD_TOP)/esp"
  mkdir $"($esp)/($a.bootEntry | path dirname)" $"($esp)/EFI/Linux" $"($esp)/EFI/loader"
  # Secure Boot: the same db key and certificate as the UKI (lib/image/uki.nix); enforcing
  # firmware starts only a signed loader. A signing failure fails the build.
  ^systemd-sbsign sign $a.systemdBoot --private-key $a.sbKey --certificate $a.sbCert --output $"($esp)/($a.bootEntry)"
  $a.loaderConf | save -f $"($esp)/EFI/loader/loader.conf"
  ^cp $a.uki $"($esp)/EFI/Linux/($a.ukiName)"
  log $"loader: ($a.bootEntry) signed with ($a.sbCert | path basename), loader.conf: (($a.loaderConf | lines | where {|l| not ($l | str starts-with '#') and ($l | str trim) != ''}) | str join ', ')"

  # the two partition UUIDs systemd derives from the root hash
  let roothash = (open --raw $a.roothash | str trim)
  let usr_uuid = (uuid-of ($roothash | str substring 0..<32))
  let verity_uuid = (uuid-of ($roothash | str substring 32..<64))
  log $"usr-a ($usr_uuid), usr-a-verity ($verity_uuid)"

  let defs = $"($env.NIX_BUILD_TOP)/repart.d"
  mkdir $defs
  for e in ($a.definitions | transpose name text) {
    $e.text
      | str replace -a "{esp}" $esp
      | str replace -a "{usr}" $a.usr
      | str replace -a "{verity}" $a.verity
      | str replace -a "{sig}" $a.sig
      | str replace -a "{usrUuid}" $usr_uuid
      | str replace -a "{verityUuid}" $verity_uuid
      | save -f $"($defs)/($e.name)"
  }

  # straight into the output: the file is sparse (20 GiB of slots) and the store is one rename away
  $env.SOURCE_DATE_EPOCH = ($a.epoch | into string)
  let disk = $"($out)/disk.raw"
  ^systemd-repart --empty=create --size=auto --offline=yes --dry-run=no --architecture $a.architecture --sector-size 512 --seed $a.seed --definitions $defs --json=pretty $disk
    | save -f $"($out)/disk.json"
  log $"disk.raw: (ls $disk | get size.0) \((^du -k $disk | split row "\t" | first) KiB allocated\)"
}
