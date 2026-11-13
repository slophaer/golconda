# disk.nu: systemd-repart over the rendered definitions, the release directory and its signed
# index; steps of the signer (lib/image/sign.nu). The parameters come from the manifest's `disk`
# (lib/image/disk.nix diskParams): definitions (name -> INI text with {esp} {usr} {verity} {sig}
# {usrUuid} {verityUuid}), architecture, seed, epoch.

use common.nu *

# A UUID (8-4-4-4-12) from 32 hex digits
export def uuid-of [hex: string]: nothing -> string {
  [($hex | str substring 0..<8) ($hex | str substring 8..<12) ($hex | str substring 12..<16) ($hex | str substring 16..<20) ($hex | str substring 20..<32)] | str join "-"
}

# The two partition UUIDs systemd derives from the root hash: usr its first 128 bits,
# usr-verity its last (systemd-veritysetup-generator(8))
export def partition-uuids [roothash: string]: nothing -> record {
  {usr: (uuid-of ($roothash | str substring 0..<32)), verity: (uuid-of ($roothash | str substring 32..<64))}
}

# esp DIR LOADER UKI L EPOCH AUTO: the ESP's content in DIR: the signed systemd-boot where
# bootctl puts it (L.espPaths: the primary copy and the removable-media path), its policy where
# systemd-boot reads it (L.confPath), the UKI where it looks, and the files AUTO (the Secure Boot
# enrolment files, lib/image/enrol.nu; none without Secure Boot) at L.enrolPath. Every file gets
# the time EPOCH: mcopy writes each file's time into the FAT, so the disk does not depend on when
# the release was signed.
export def esp [dir: string, loader: string, uki: string, l: record, epoch: int, auto: list<string>] {
  mkdir $"($dir)/EFI/Linux"
  for p in $l.espPaths {
    mkdir $"($dir)/($p | path dirname)"
    ^cp $loader $"($dir)/($p)"
  }
  mkdir $"($dir)/($l.confPath | path dirname)"
  $l.conf | save -f $"($dir)/($l.confPath)"
  ^cp $uki $"($dir)/EFI/Linux/($uki | path basename)"
  if ($auto | is-not-empty) {
    mkdir $"($dir)/($l.enrolPath)"
    for f in $auto { ^cp $f $"($dir)/($l.enrolPath)/($f | path basename)" }
  }
  ^find $dir -exec touch -h -d $"@($epoch)" "{}" +
  let keys = (if ($auto | is-empty) { "" } else { [", " $l.enrolPath ": " ($auto | path basename | str join " ")] | str join })
  log $"ESP: ($l.espPaths | str join ', '), ($l.confPath): (($l.conf | lines | where {|x| not ($x | str starts-with '#') and ($x | str trim) != ''}) | str join ', ')($keys)"
}

# make OUT P FILES UUIDS: OUT/disk.raw and repart's own listing OUT/disk.json, from the
# definitions with the ESP directory and the slot A images of FILES (esp usr verity sig) and the
# UUIDS. --offline: no loop device, no root; the usr slots are 10 GiB each (image/repart.nix), so
# the file is sparse.
#
# The ESP: repart passes SOURCE_DATE_EPOCH on to mkfs.fat, which writes it as the volume label's
# time (packages/dosfstools/source-date-epoch.patch), and its own `-i <volume ID>`, derived from
# the partition UUID. So two signings make the same file system: packages.<system>.disk-reproducible
# signs the test image twice and compares the bytes.
export def make [out: string, p: record, files: record, uuids: record] {
  let defs = (mktemp -d -t "golconda-repart-XXXXXX")
  for e in ($p.definitions | transpose name text) {
    $e.text
      | str replace -a "{esp}" $files.esp
      | str replace -a "{usr}" $files.usr
      | str replace -a "{verity}" $files.verity
      | str replace -a "{sig}" $files.sig
      | str replace -a "{usrUuid}" $uuids.usr
      | str replace -a "{verityUuid}" $uuids.verity
      | save -f $"($defs)/($e.name)"
  }
  let disk = $"($out)/disk.raw"
  let args = [--size=auto --offline=yes --architecture $p.architecture --sector-size 512 --seed $p.seed --definitions $defs]
  with-env {SOURCE_DATE_EPOCH: ($p.epoch | into string)} {
    ^systemd-repart --empty=create --dry-run=no ...$args --json=pretty $disk
      | save -f $"($out)/disk.json"
  }
  rm -rf $defs
  log $"disk.raw: (ls $disk | get size.0) \((^du -k $disk | split row "\t" | first) KiB allocated\)"
}

# index RELEASE FILES: RELEASE/SHA256SUMS over FILES (a table of name and path, in the index's
# fixed order), each file moved into RELEASE under its name and readable by all: a web server
# serves them (veritysetup writes its hash file 0600)
export def index [release: string, files: table] {
  for f in $files {
    ^mv $f.path $"($release)/($f.name)"
    ^chmod 0644 $"($release)/($f.name)"
  }
  $files
    | each {|f| $"(open --raw $"($release)/($f.name)" | hash sha256)  ($f.name)" }
    | str join "\n"
    | $"($in)\n"
    | save -f $"($release)/SHA256SUMS"
}

# sign-index RELEASE KEY EPOCH KEYRING: SHA256SUMS.gpg, a detached binary OpenPGP signature of
# SHA256SUMS with the release key, what systemd-pull checks for Verify=yes
# (image/sysupdate.nix). KEY is the armored secret key. The signature time is the version's
# epoch, or the key's creation time when the key is newer: Ed25519 is deterministic, so signing
# again gives the same bytes. The signature is checked with gpgv against KEYRING, the public key
# the image carries, before it is kept.
export def sign-index [release: string, key: string, epoch: int, keyring: string] {
  let home = (mktemp -d -t "golconda-gnupg-XXXXXX")
  ^chmod 700 $home
  with-env {GNUPGHOME: $home} {
    ^gpg --batch --pinentry-mode loopback --passphrase '' --import $key e> /dev/null
    let sec = (^gpg --batch --with-colons --list-secret-keys | lines | where {|l| $l starts-with "sec:" })
    if ($sec | length) != 1 {
      error make {msg: $"($key): expected one secret key, found ($sec | length)"}
    }
    let created = ($sec | first | split row ':' | get 5 | into int)
    let at = ([$epoch ($created + 1)] | math max)
    ^gpg --batch --yes --pinentry-mode loopback --passphrase '' --faked-system-time $"($at)!" --detach-sign --output $"($release)/SHA256SUMS.gpg" $"($release)/SHA256SUMS" e> /dev/null
    ^gpgconf --kill gpg-agent
  }
  rm -rf $home
  verify-index $release $keyring
  log "release: SHA256SUMS.gpg"
}

# verify-index RELEASE KEYRING: SHA256SUMS.gpg must be a signature of SHA256SUMS by the key in
# KEYRING (binary OpenPGP), checked by gpgv in a home of its own
export def verify-index [release: string, keyring: string] {
  let home = (mktemp -d -t "golconda-gpgv-XXXXXX")
  ^chmod 700 $home
  let v = (do { ^gpgv --homedir $home --keyring $keyring $"($release)/SHA256SUMS.gpg" $"($release)/SHA256SUMS" } | complete)
  rm -rf $home
  if $v.exit_code != 0 {
    error make {msg: $"SHA256SUMS.gpg does not verify against ($keyring | path basename), the key the image carries: ($v.stderr | str trim)"}
  }
}
