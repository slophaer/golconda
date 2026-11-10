# sign.nu: the signer. It takes the unsigned outputs of the image chain (lib/image/manifest.nix:
# manifest.json names the /usr tree, the initrd, the kernel, the unsigned loader and every
# parameter) and a key set, and writes the signed release:
#
#   OUT/disk.raw, OUT/disk.json   the disk image (lib/image/disk.nu)
#   OUT/release/                  the four release files, SHA256SUMS and SHA256SUMS.gpg
#   OUT/cmdline                   the UKI's cmdline, for the record
#
# The steps, in order: check that each private key is the half of the public key the image
# carries; sign systemd-boot (db key); put it into a copy of the /usr tree; mkfs.erofs; the
# verity hash tree and the root hash signature (db key); the UKI with its Secure Boot signature
# (db key) and its .pcrsig (PCR key); the ESP and systemd-repart; SHA256SUMS and its signature
# (release key). Each step is deterministic for the same inputs and keys: the times (the
# signing time of systemd-sbsign too, through SOURCE_DATE_EPOCH) and identifiers come from the
# version, and RSA PKCS#1 v1.5 and Ed25519 signatures do not draw random numbers.
#
# Nix runs no step of this with a private key, except for test images: there a derivation runs
# the same program with the throwaway keys (lib/image/chain.nix signWithTestKeys).
# `golconda release build` runs it on the release host with the key set where it lies
# (docs/design/trust.md).
#
# A key set is a directory in scripts/make-keys' layout: secureboot/db.key, pcr/pcr.key and
# release/index.key are read. The certificates and public keys come from the manifest, never
# from the key set, so a signature is always by the key the image trusts.

use common.nu *
use erofs.nu
use verity.nu
use loader.nu
use uki.nu
use disk.nu

# private-keys DB PCR INDEX: the private key files of the three key sets (each a directory; the
# same one unless a rotation keeps the PCR or the release key, docs/reference/release.md)
#
# The hook for keys on a token: a key set that is a PKCS#11 URI (`pkcs11:…`) would give the
# tools a provider instead of a file (systemd-sbsign --private-key-source=provider:pkcs11, ukify
# --signing-provider and --pcr-private-key with a URI, openssl smime -provider pkcs11, and gpg
# through scdaemon for the release key). Not built: such a set is refused here.
export def private-keys [db: string, pcr: string, index: string]: nothing -> record {
  for k in [$db $pcr $index] {
    if ($k | str starts-with "pkcs11:") {
      error make {msg: $"($k): a PKCS#11 key is not supported yet; give a key directory \(scripts/make-keys\)"}
    }
  }
  let keys = {
    dbKey: ($db | path join secureboot/db.key | path expand)
    pcrKey: ($pcr | path join pcr/pcr.key | path expand)
    indexKey: ($index | path join release/index.key | path expand)
  }
  for f in ($keys | values) {
    if not ($f | path exists) {
      error make {msg: $"($f): no such key \(a key set is a directory in the layout of scripts/make-keys\)"}
    }
  }
  $keys
}

# check-keys PRIVATE PUBLIC: each private key must be the half of the public key the image
# carries (the manifest's publicKeys): the db certificate (the firmware db, and the kernel
# without Secure Boot), the PCR public key (.pcrpkey) and the release keyring (import-pubring.pgp).
# A signature by another key would make a release that does not boot or does not install.
export def check-keys [priv: record, pub: record] {
  let cert_key = (^openssl x509 -in $pub.dbCert -noout -pubkey)
  let db_key = (^openssl pkey -in $priv.dbKey -pubout)
  if $cert_key != $db_key {
    error make {msg: $"($priv.dbKey) is not the key of the db certificate this image trusts \((fingerprint $pub.dbCert)\)"}
  }
  let pcr_pub = (^openssl pkey -pubin -in $pub.pcrPublicKey -pubout)
  let pcr_key = (^openssl pkey -in $priv.pcrKey -pubout)
  if $pcr_pub != $pcr_key {
    error make {msg: $"($priv.pcrKey) is not the key of the PCR public key this image carries"}
  }
  let want = (pgp-fingerprint $pub.indexKeyring "pub")
  let have = (pgp-fingerprint $priv.indexKey "sec")
  if $want != $have {
    error make {msg: $"($priv.indexKey) is the OpenPGP key ($have), but this image trusts ($want)"}
  }
  log $"keys: db ((fingerprint $pub.dbCert)), PCR, release ($want): each is the half the image carries"
}

# The SHA-256 fingerprint of a PEM certificate
def fingerprint [cert: string]: nothing -> string {
  ^openssl x509 -in $cert -noout -fingerprint -sha256 | str trim | split row "=" | last
}

# The fingerprint of the one primary key of KIND (pub or sec) in an OpenPGP file
def pgp-fingerprint [file: string, kind: string]: nothing -> string {
  let home = (mktemp -d -t "golconda-gnupg-XXXXXX")
  ^chmod 700 $home
  let rows = (with-env {GNUPGHOME: $home} { ^gpg --batch --with-colons --show-keys $file e> /dev/null | lines })
  rm -rf $home
  let primaries = ($rows | where {|l| $l starts-with $"($kind):" })
  if ($primaries | length) != 1 {
    error make {msg: $"($file): expected one ($kind) key, found ($primaries | length)"}
  }
  # the first fpr line follows the primary key
  $rows | where {|l| $l starts-with "fpr:" } | first | split row ':' | get 9
}

# sign UNSIGNED KEYSETS OUT: the release of the unsigned outputs UNSIGNED (a directory with
# manifest.json), signed with KEYSETS {db pcr index} (key set directories), written to OUT. OUT
# may exist, but must not hold a release yet.
export def main [unsigned: string, sets: record, out: string] {
  let m = (open $"($unsigned)/manifest.json")
  let pub = $m.publicKeys
  let priv = (private-keys $sets.db $sets.pcr $sets.index)
  check-keys $priv $pub

  for f in [disk.raw release] {
    if ($"($out)/($f)" | path exists -n) {
      error make {msg: $"($out)/($f) exists: the signer writes a new release, it does not replace one"}
    }
  }
  mkdir $out
  # systemd-sbsign (the loader, and the UKI through ukify) puts a signing time into the
  # signature: the version's, not the clock's
  $env.SOURCE_DATE_EPOCH = ($m.disk.epoch | into string)
  let work = $"($out)/.work"
  mkdir $work

  # the loader first: /usr carries it
  let signed_loader = $"($work)/($m.loader.usrPath | path basename)"
  loader sign $m.loader.unsigned $signed_loader $priv.dbKey $pub.dbCert

  # the /usr tree with the signed loader where golconda-loader-update reads it (modules/base)
  let tree = $"($work)/usr"
  ^cp -RP --preserve=mode $m.usrTree $tree
  let usr_loader = $"($tree)/($m.loader.usrPath)"
  if ($usr_loader | path exists -n) {
    error make {msg: $"($m.usrTree) already has ($m.loader.usrPath): only the signer puts the signed loader there"}
  }
  let dir = ($usr_loader | path dirname)
  if not ($dir | path exists) {
    error make {msg: $"($m.usrTree) has no ($m.loader.usrPath | path dirname): systemd-boot is not in /usr"}
  }
  if (open --raw $"($tree)/($m.loader.usrConfPath | str replace -r '^/usr/' '')") != $m.loader.conf {
    error make {msg: $"($m.usrTree)($m.loader.usrConfPath | str replace -r '^/usr' '') is not image/loader.nix's loader.conf"}
  }
  let mode = (^stat -c %a $dir | str trim)
  ^chmod u+w $dir
  ^cp $signed_loader $usr_loader
  ^chmod 0444 $usr_loader
  ^chmod $mode $dir
  log $"/usr/($m.loader.usrPath): the signed loader"

  let usr = $"($work)/($m.erofs.fileName)"
  erofs make $tree $usr $m.erofs
  ^chmod -R u+w $tree
  rm -rf $tree

  let roothash = (verity make $usr $work $m.verity $priv.dbKey $pub.dbCert)
  let sig = $"($work)/($m.verity.sigFile)"
  let hash = $"($work)/($m.verity.hashFile)"

  let uki = $"($work)/($m.uki.fileName)"
  let cmdline = (uki make $m.uki $roothash $sig {dbKey: $priv.dbKey dbCert: $pub.dbCert pcrKey: $priv.pcrKey pcrPublic: $pub.pcrPublicKey} $uki)

  # the disk: the ESP starts as the machine's golconda-loader-update would leave it
  let uuids = (disk partition-uuids $roothash)
  log $"usr-a ($uuids.usr), usr-a-verity ($uuids.verity)"
  let esp = $"($work)/esp"
  disk esp $esp $signed_loader $uki $m.loader $m.disk.epoch
  disk make $out $m.disk {esp: $esp usr: $usr verity: $hash sig: $sig} $uuids

  # the release under the names the sysupdate sources match: the data and hash files carry the
  # UUIDs above, which sysupdate gives the slot it writes, so the new UKI's usrhash= finds it
  let release = $"($out)/release"
  mkdir $release
  disk index $release [
    [name path];
    [($m.release.usr | str replace "@u" $uuids.usr) $usr]
    [($m.release.verity | str replace "@u" $uuids.verity) $hash]
    [$m.release.sig $sig]
    [$m.release.uki $uki]
  ]
  disk sign-index $release $priv.indexKey $m.disk.epoch $pub.indexKeyring
  $cmdline | save -f $"($out)/cmdline"
  rm -rf $work
  log $"release: (ls $release | get name | path basename | str join ' ')"
}
