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
# (db key) and its .pcrsig (PCR key); the ESP, with the key set's Secure Boot enrolment files
# (written once by scripts/make-keys; no PK or KEK key is read), and systemd-repart; SHA256SUMS
# and its signature (release key). Each step is deterministic for the same inputs and keys: the times (the
# signing time of systemd-sbsign too, through SOURCE_DATE_EPOCH) and identifiers come from the
# version, and RSA PKCS#1 v1.5 and Ed25519 signatures do not draw random numbers.
#
# Nix runs no step of this with a private key, except for test images: there a derivation runs
# the same program with the throwaway keys (lib/image/chain.nix signWithTestKeys).
# `golconda release build` runs it on the release host with the key set where it lies
# (docs/design/trust.md).
#
# A key set is a directory in scripts/make-keys' layout: secureboot/db.key, pcr/pcr.key and
# release/index.key are read, or for the db and PCR keys a `pkcs11:` URI of a key on a token
# (secureboot/db.pkcs11, pcr/pcr.pkcs11; private-keys). The certificates and public keys come
# from the manifest, never from the key set, so a signature is always by the key the image
# trusts.

use common.nu *
use erofs.nu
use verity.nu
use loader.nu
use uki.nu
use disk.nu
use enrol.nu

# private-keys DB PCR INDEX: the private keys of the three key sets (each a directory; the same
# one unless a rotation keeps the PCR or the release key, docs/reference/release.md). Each key is
# a file path, or a `pkcs11:` URI when the set holds the key on a token: secureboot/db.pkcs11 and
# pcr/pcr.pkcs11 in place of db.key and pcr.key, one line with the URI (RFC 7512). The token
# signs; the key never leaves it (use-token). The release key is a file: gpg signs the index,
# and gpg takes no PKCS#11 key (docs/design/trust.md, Keys on a token).
export def private-keys [db: string, pcr: string, index: string]: nothing -> record {
  for k in [$db $pcr $index] {
    if ($k | str starts-with "pkcs11:") {
      error make {msg: $"($k): a key set is a directory; a key on a token is a URI in its secureboot/db.pkcs11 or pcr/pcr.pkcs11 \(docs/reference/release.md\)"}
    }
  }
  let index_uri = ($index | path join release/index.pkcs11 | path expand)
  if ($index_uri | path exists) {
    error make {msg: $"($index_uri): the release key cannot be on a PKCS#11 token: gpg signs SHA256SUMS and takes no PKCS#11 key; keep release/index.key \(docs/design/trust.md\)"}
  }
  {
    dbKey: (key-of $db secureboot/db)
    pcrKey: (key-of $pcr pcr/pcr)
    indexKey: (key-of $index release/index)
  }
}

# The key BASE (secureboot/db, pcr/pcr, release/index) of the set DIR: BASE.key, a file, or the
# URI in BASE.pkcs11, not both
def key-of [dir: string, base: string]: nothing -> string {
  let file = ($dir | path join $"($base).key" | path expand)
  let uri_file = ($dir | path join $"($base).pkcs11" | path expand)
  match [($file | path exists) ($uri_file | path exists)] {
    [true true] => {
      error make {msg: $"($dir): both ($base).key and ($base).pkcs11: a key is a file or on a token, not both"}
    }
    [true false] => $file
    [false true] => {
      let uri = (open --raw $uri_file | decode utf-8 | lines | where {|l| ($l | str trim) != "" } | first | str trim)
      if not ($uri | str starts-with "pkcs11:") {
        error make {msg: $"($uri_file): not a pkcs11: URI \(RFC 7512, e.g. pkcs11:token=golconda;object=db;type=private\)"}
      }
      $uri
    }
    _ => {
      error make {msg: $"($file): no such key, and no ($base).pkcs11 \(a key set is a directory in the layout of scripts/make-keys\)"}
    }
  }
}

# use-token PRIVATE DIR MODULE: when a key of PRIVATE is on a token, make the tools reach it: an
# OpenSSL configuration (OPENSSL_CONF, DIR/openssl.cnf) that gives pkcs11-provider the
# PKCS#11 module MODULE (a YubiKey's, or SoftHSM's in the tests) and keeps the token from serving
# digests: they stay with the default provider, and a module that hashes with OpenSSL itself
# (SoftHSM) would call back into itself. The tools load the provider by name, from
# OPENSSL_MODULES (the signer's wrapper sets it, lib/image/signer.nu). Keys in files need nothing.
export def --env use-token [priv: record, dir: string, module?: string] {
  let token = ([$priv.dbKey $priv.pcrKey] | where {|k| on-token $k })
  if ($token | is-empty) { return }
  if $module == null {
    error make {msg: $"($token | first) is on a token: give the PKCS#11 module with --pkcs11-module \(a YubiKey's libykcs11.so\)"}
  }
  if not ($module | path exists) {
    error make {msg: $"($module): no such PKCS#11 module"}
  }
  let conf = ($dir | path join openssl.cnf)
  [
    "openssl_conf = openssl_init"
    "[openssl_init]"
    "providers = provider_sect"
    "[provider_sect]"
    "default = default_sect"
    "pkcs11 = pkcs11_sect"
    "[default_sect]"
    "activate = 1"
    "[pkcs11_sect]"
    $"pkcs11-module-path = ($module | path expand)"
    "pkcs11-module-block-operations = digest"
  ] | str join "\n" | $"($in)\n" | save -f $conf
  $env.OPENSSL_CONF = $conf
  log $"PKCS#11: ($token | length) key\(s\) on a token, module ($module)"
}

# The public half of a private key (a file or a URI), as PEM SubjectPublicKeyInfo: a token's
# provider writes RSA keys as PKCS#1, so it goes through the default provider once more
def public-of-key [key: string]: nothing -> string {
  if (on-token $key) {
    let der = (mktemp -t "golconda-pub-XXXXXX")
    ^openssl pkey ...(openssl-key-source $key) -in $key -pubout -outform DER -out $der
    let pem = (^openssl pkey -pubin -inform DER -in $der -pubout)
    rm $der
    $pem
  } else {
    ^openssl pkey -in $key -pubout
  }
}

# check-keys PRIVATE PUBLIC: each private key must be the half of the public key the image
# carries (the manifest's publicKeys): the db certificate (the firmware db, and the kernel
# without Secure Boot), the PCR public key (.pcrpkey) and the release keyring (import-pubring.pgp).
# A signature by another key would make a release that does not boot or does not install.
export def check-keys [priv: record, pub: record] {
  let cert_key = (^openssl x509 -in $pub.dbCert -noout -pubkey)
  let db_key = (public-of-key $priv.dbKey)
  if $cert_key != $db_key {
    error make {msg: $"($priv.dbKey) is not the key of the db certificate this image trusts \((fingerprint $pub.dbCert)\)"}
  }
  let pcr_pub = (^openssl pkey -pubin -in $pub.pcrPublicKey -pubout)
  let pcr_key = (public-of-key $priv.pcrKey)
  if $pcr_pub != $pcr_key {
    error make {msg: $"($priv.pcrKey) is not the key of the PCR public key this image carries"}
  }
  let want = (pgp-fingerprint $pub.indexKeyring "pub")
  let have = (pgp-fingerprint $priv.indexKey "sec")
  if $want != $have {
    error make {msg: $"($priv.indexKey) is the OpenPGP key ($have), but this image trusts ($want)"}
  }
  let where = {|k| if (on-token $k) { " on a token" } else { "" } }
  log $"keys: db ((fingerprint $pub.dbCert))(do $where $priv.dbKey), PCR(do $where $priv.pcrKey), release ($want): each is the half the image carries"
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

# enrol-files MANIFEST SET DBCERT: the enrolment files of the db key set SET for the ESP
# (secureboot/auth/microsoft or golconda, the manifest's loader.enrolSet), checked against SET's
# PK.crt and KEK.crt and the image's db certificate DBCERT (lib/image/enrol.nu check-set); none
# for an image without Secure Boot. A Secure Boot image needs them: a set without them was made
# before scripts/make-keys wrote them.
def enrol-files [m: record, set: string, db_cert: string]: nothing -> list<string> {
  if not $m.loader.enrol {
    log "loader/keys/auto: none, the image is for a host without Secure Boot"
    return []
  }
  let sb = ($set | path join secureboot | path expand)
  let files = (enrol check-set $"($sb)/auth/($m.loader.enrolSet)" {pk: $"($sb)/PK.crt" kek: $"($sb)/KEK.crt" db: $db_cert})
  log $"loader/keys/auto: ($m.loader.enrolSet): ($files | path basename | str join ', ')"
  $files
}

# sign UNSIGNED KEYSETS OUT [MODULE]: the release of the unsigned outputs UNSIGNED (a directory
# with manifest.json), signed with KEYSETS {db pcr index} (key set directories), written to OUT.
# OUT may exist, but must not hold a release yet. MODULE is the PKCS#11 module of a token that
# holds a key (use-token).
export def main [unsigned: string, sets: record, out: string, pkcs11_module?: string] {
  let m = (open $"($unsigned)/manifest.json")
  let pub = $m.publicKeys
  let priv = (private-keys $sets.db $sets.pcr $sets.index)
  let token_dir = (mktemp -d -t "golconda-pkcs11-XXXXXX")
  use-token $priv $token_dir $pkcs11_module
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
  let auto = (enrol-files $m $sets.db $pub.dbCert)
  disk esp $esp $signed_loader $uki $m.loader $m.disk.epoch $auto
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
  rm -rf $token_dir
  log $"release: (ls $release | get name | path basename | str join ' ')"
}
