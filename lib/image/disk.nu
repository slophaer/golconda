# disk.nu: systemd-repart over the rendered definitions (lib/image/disk.nix).
#
# Structured attrs: definitions (name -> INI text with {esp} {usr} {verity} {sig} {usrUuid}
# {verityUuid}), usr, verity, sig, roothash, uki, ukiName, loader, usrLoader, usrLoaderConf,
# loaderPaths, loaderConfPath, architecture, seed, epoch, loaderConf, release (usr verity sig
# uki -> file name, `@u` where the UUID goes).

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

  # The machine installs its loader from /usr (golconda-loader-update, modules/base): the ESP
  # must start with the same bytes, or the first good boot rewrites a loader nobody tested
  if (open --raw $a.loader | hash sha256) != (open --raw $a.usrLoader | hash sha256) {
    error make { msg: $"($a.loader) is not the loader the /usr tree carries at ($a.usrLoader)" }
  }
  if (open --raw $a.usrLoaderConf) != $a.loaderConf {
    error make { msg: $"($a.usrLoaderConf) is not image/loader.nix's loader.conf" }
  }

  # the ESP's content: the signed systemd-boot where bootctl puts it (the primary copy and the
  # removable-media path), its policy where systemd-boot reads it, the UKI where it looks
  let esp = $"($env.NIX_BUILD_TOP)/esp"
  mkdir $"($esp)/EFI/Linux"
  for p in $a.loaderPaths {
    mkdir $"($esp)/($p | path dirname)"
    ^cp $a.loader $"($esp)/($p)"
  }
  mkdir $"($esp)/($a.loaderConfPath | path dirname)"
  $a.loaderConf | save -f $"($esp)/($a.loaderConfPath)"
  ^cp $a.uki $"($esp)/EFI/Linux/($a.ukiName)"
  log $"loader: ($a.loaderPaths | str join ', ') = ($a.usrLoader | path basename) from /usr, ($a.loaderConfPath): (($a.loaderConf | lines | where {|l| not ($l | str starts-with '#') and ($l | str trim) != ''}) | str join ', ')"

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

  # the release under the names the sysupdate sources match: the data and hash files carry the
  # UUIDs above, which sysupdate gives the slot it writes, so the new UKI's usrhash= finds it
  let release = $"($out)/release"
  mkdir $release
  let files = [
    [name source];
    [($a.release.usr | str replace "@u" $usr_uuid) $a.usr]
    [($a.release.verity | str replace "@u" $verity_uuid) $a.verity]
    [$a.release.sig $a.sig]
    [$a.release.uki $a.uki]
  ]
  for f in $files {
    ^ln -s $f.source $"($release)/($f.name)"
  }
  $files
    | each {|f| $"(open --raw $f.source | hash sha256)  ($f.name)" }
    | str join "\n"
    | $"($in)\n"
    | save -f $"($release)/SHA256SUMS"
  sign-index $release $a.indexKey $a.epoch
  log $"release: (ls $release | get name | path basename | str join ' ')"
}

# SHA256SUMS.gpg: a detached binary OpenPGP signature of SHA256SUMS with the release key, what
# systemd-pull checks for Verify=yes (image/sysupdate.nix). The signature time is the version's
# epoch, or the key's creation time when the key is newer: Ed25519 is deterministic, so a rebuild
# gives the same bytes. The signature is checked against the public half before it is kept.
def sign-index [release: string, key: string, epoch: int] {
  let home = $"($env.TMPDIR? | default /tmp)/gnupg-index"
  mkdir $home
  ^chmod 700 $home
  with-env {GNUPGHOME: $home} {
    ^gpg --batch --pinentry-mode loopback --passphrase '' --import $key e> /dev/null
    let sec = (^gpg --batch --with-colons --list-secret-keys | lines | where {|l| $l starts-with "sec:" })
    if ($sec | length) != 1 {
      error make {msg: $"($key): expected one secret key, found ($sec | length)"}
    }
    let created = ($sec | first | split row ':' | get 5 | into int)
    let at = ([$epoch ($created + 1)] | math max)
    ^gpg --batch --yes --pinentry-mode loopback --passphrase '' --faked-system-time $"($at)!" --detach-sign --output $"($release)/SHA256SUMS.gpg" $"($release)/SHA256SUMS"
    let v = (^gpg --batch --verify $"($release)/SHA256SUMS.gpg" $"($release)/SHA256SUMS" | complete)
    if $v.exit_code != 0 {
      error make {msg: $"SHA256SUMS.gpg does not verify: ($v.stderr)"}
    }
    ^gpgconf --kill gpg-agent
  }
  rm -rf $home
  log "release: SHA256SUMS.gpg"
}
