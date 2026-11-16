# enrol.nu: the Secure Boot variables that systemd-boot enrols from the ESP: the two sets under
# secureboot/auth/ that scripts/make-keys writes once into a key set (golconda-enrol-auth,
# enrol-main.nu) and the signer checks and copies (`check-set`); docs/design/bootloader.md,
# "Enrolment". They depend on the certificates only, not on an image.
#
# Each file is a time-based authenticated variable (UEFI 2.10, 8.2.2): EFI_VARIABLE_AUTHENTICATION_2
# (an EFI_TIME and a WIN_CERTIFICATE_UEFI_GUID with a PKCS#7 SignedData), then the payload, a
# series of EFI_SIGNATURE_LISTs. The signature covers the variable name (UTF-16, no NUL), its
# vendor GUID, the attributes, the EFI_TIME and the payload. The SignedData has no signed
# attributes and no ContentInfo around it. RSA PKCS#1 v1.5 draws no random numbers, so the same
# keys and time give the same files. efitools writes them; `verify` takes a file apart with code
# of its own and has openssl check the signature.

use common.nu *

# the vendor GUIDs of the variables, and the types of a signature list entry and a WIN_CERTIFICATE
export const global_guid = "8be4df61-93ca-11d2-aa0d-00e098032b8c"
export const db_guid = "d719b2cb-3d3a-4596-a3bc-dad00e67656f"
const x509_guid = "a5c059a1-94e4-4aa7-87b5-ab155c2bf072"
const pkcs7_guid = "4aafd29d-68df-49ee-8aa9-347d375665a7"
# the SignatureOwner of every entry Golconda writes, and of Microsoft's (as Microsoft's own
# updates and systemd's loader.conf(5) name it): the firmware keeps it, nothing verifies it
export const owner_guid = "30b1c522-c5c2-4f0b-b805-31f1d155154c"
export const microsoft_guid = "77fa9abd-0359-4d32-bd60-28f4e78f784b"
# NON_VOLATILE | BOOTSERVICE_ACCESS | RUNTIME_ACCESS | TIME_BASED_AUTHENTICATED_WRITE_ACCESS
const attributes = 0x27
# the one OID that may follow a ContentInfo's SEQUENCE: pkcs7-signedData (1.2.840.113549.1.7.2)
const signed_data_oid = 0x[06 09 2a 86 48 86 f7 0d 01 07 02]

# the variables of a set, in the order systemd-boot writes them, the vendor GUID of each, and the
# key that signs it
export const variables = [
  [name guid signer];
  [db $db_guid KEK]
  [dbx $db_guid KEK]
  [KEK $global_guid PK]
  [PK $global_guid PK]
]

# Microsoft's objects in packages/secureboot-objects (share/secureboot-objects), by variable
export const microsoft_kek = [KEK/microsoft-kek-ca-2011.der KEK/microsoft-kek-2k-ca-2023.der]
export const microsoft_db = [db/microsoft-uefi-ca-2011.der db/microsoft-uefi-ca-2023.der db/microsoft-option-rom-uefi-ca-2023.der]
export const microsoft_dbx = "dbx/DBXUpdate-amd64.bin"

# N as COUNT little-endian bytes
def le [n: int, count: int]: nothing -> binary {
  $n | into binary | bytes at 0..<($count)
}

# A GUID in EFI's byte order: the first three fields little-endian, the rest as written
def guid [g: string]: nothing -> binary {
  let p = ($g | split row "-")
  let swap = {|h| $h | decode hex | bytes reverse }
  [(do $swap $p.0) (do $swap $p.1) (do $swap $p.2) ($p.3 | decode hex) ($p.4 | decode hex)] | bytes collect
}

# The variable name as UTF-16LE without the NUL (the names are ASCII)
def ucs2 [name: string]: nothing -> binary {
  $name | split chars | each {|c| $c | encode utf-8 | bytes add 0x[00] --end } | bytes collect
}

# The DER of a certificate file, PEM or DER
def der [cert: string]: nothing -> binary {
  let f = (mktemp -t "golconda-der-XXXXXX")
  let form = (if ($cert | str ends-with ".der") { "DER" } else { "PEM" })
  ^openssl x509 -inform $form -in $cert -outform DER -out $f
  let b = (open --raw $f | into binary)
  rm -f $f
  $b
}

# esl CERT [OWNER]: an EFI_SIGNATURE_LIST with CERT (PEM or DER) as its one EFI_CERT_X509 entry,
# owned by OWNER, as efitools' cert-to-efi-sig-list writes it
export def esl [cert: string, owner: string = $owner_guid]: nothing -> binary {
  let work = (mktemp -d -t "golconda-esl-XXXXXX")
  der $cert | save -f --raw $"($work)/cert.der"
  ^openssl x509 -inform DER -in $"($work)/cert.der" -outform PEM -out $"($work)/cert.pem"
  ^cert-to-efi-sig-list -g $owner $"($work)/cert.pem" $"($work)/list.esl" | ignore
  let b = (open --raw $"($work)/list.esl" | into binary)
  rm -rf $work
  $b
}

# first-x509 LISTS: the DER of the first signature list's one entry, when that list is
# EFI_CERT_X509 with no header and one entry (what `esl` writes), else null; read without efitools
def first-x509 [lists: binary]: nothing -> any {
  if ($lists | bytes length) < 44 or ($lists | bytes at 0..<16) != (guid $x509_guid) {
    return null
  }
  let size = ($lists | bytes at 16..<20 | into int -e little)
  let header = ($lists | bytes at 20..<24 | into int -e little)
  let each = ($lists | bytes at 24..<28 | into int -e little)
  if $header != 0 or $each < 16 or $size != 28 + $each or $size > ($lists | bytes length) {
    return null
  }
  $lists | bytes at 44..<$size
}

# auth-payload FILE: the signature lists of an authenticated variable (Microsoft's dbx update)
export def auth-payload [file: string]: nothing -> binary {
  let b = (open --raw $file | into binary)
  let len = ($b | bytes at 16..<20 | into int -e little)
  $b | bytes at (16 + $len)..
}

# The DER length bytes of N
def der-length [n: int]: nothing -> binary {
  if $n < 0x80 {
    le $n 1
  } else if $n < 0x100 {
    [0x[81] (le $n 1)] | bytes collect
  } else if $n < 0x10000 {
    [0x[82] (le $n 2 | bytes reverse)] | bytes collect
  } else {
    [0x[83] (le $n 3 | bytes reverse)] | bytes collect
  }
}

# content-info SIGNED: the SignedData wrapped in a ContentInfo again, which openssl reads
export def content-info [signed: binary]: nothing -> binary {
  let explicit = ([0x[a0] (der-length ($signed | bytes length)) $signed] | bytes collect)
  let body = ([$signed_data_oid $explicit] | bytes collect)
  [0x[30] (der-length ($body | bytes length)) $body] | bytes collect
}

# auth NAME EPOCH PAYLOAD KEY CERT: the authenticated variable for an enrolment of PAYLOAD
# (signature lists), signed by KEY whose certificate CERT goes into the SignedData: efitools'
# sign-efi-sig-list, which knows the vendor GUID of PK, KEK, db and dbx and sets the attributes
export def auth [name: string, epoch: int, payload: binary, key: string, cert: string]: nothing -> binary {
  let work = (mktemp -d -t "golconda-auth-XXXXXX")
  $payload | save -f --raw $"($work)/payload.esl"
  let time = ($epoch * 1_000_000_000 | into datetime | format date "%Y-%m-%d %H:%M:%S")
  ^sign-efi-sig-list -t $time -c $cert -k $key $name $"($work)/payload.esl" $"($work)/var.auth" | ignore
  let b = (open --raw $"($work)/var.auth" | into binary)
  rm -rf $work
  $b
}

# verify FILE NAME GUID CERT: FILE is an authenticated variable NAME whose signature is by the
# key of CERT; the payload is returned. A file that does not parse or verify is an error.
export def verify [file: string, name: string, vendor: string, cert: string]: nothing -> binary {
  let b = (open --raw $file | into binary)
  let len = ($b | bytes at 16..<20 | into int -e little)
  if ($b | bytes at 20..<24) != 0x[00 02 f1 0e] or ($b | bytes at 24..<40) != (guid $pkcs7_guid) {
    error make {msg: $"($file): not an EFI_VARIABLE_AUTHENTICATION_2 with a PKCS#7 signature"}
  }
  let sig = ($b | bytes at 40..<(16 + $len))
  let payload = ($b | bytes at (16 + $len)..)
  let work = (mktemp -d -t "golconda-auth-XXXXXX")
  content-info $sig | save -f --raw $"($work)/p7"
  [(ucs2 $name) (guid $vendor) (le $attributes 4) ($b | bytes at 0..<16) $payload] | bytes collect | save -f --raw $"($work)/data"
  # -nointern -certfile: the signer must be CERT's key, not a certificate the message carries
  let v = (do { ^openssl smime -verify -binary -inform DER -in $"($work)/p7" -content $"($work)/data" -certfile $cert -nointern -noverify -out /dev/null } | complete)
  rm -rf $work
  if $v.exit_code != 0 {
    error make {msg: $"($file): the signature of ($name) does not verify against ($cert | path basename): ($v.stderr | str trim)"}
  }
  $payload
}

# payloads CERTS MS: the payload of each variable of the set: CERTS {pk kek db} are the
# deployment's certificates; MS is the directory of Microsoft's objects, or null for the set
# without them (and without dbx)
export def payloads [certs: record, ms: any]: nothing -> record {
  let own = {PK: (esl $certs.pk) KEK: (esl $certs.kek) db: (esl $certs.db)}
  if $ms == null {
    return $own
  }
  let lists = {|files| $files | each {|f| esl $"($ms)/($f)" $microsoft_guid } | bytes collect }
  {
    PK: $own.PK
    KEK: ([$own.KEK (do $lists $microsoft_kek)] | bytes collect)
    db: ([$own.db (do $lists $microsoft_db)] | bytes collect)
    dbx: (auth-payload $"($ms)/($microsoft_dbx)")
  }
}

# key-pair KEY CERT: KEY must be the private half of CERT
def key-pair [key: string, cert: string] {
  if (^openssl x509 -in $cert -noout -pubkey) != (^openssl pkey -in $key -pubout) {
    error make {msg: $"($key) is not the key of ($cert)"}
  }
}

# write DIR CERTS SIGNERS MS EPOCH: DIR/microsoft/ and DIR/golconda/ with the .auth files of
# CERTS {pk kek db} (the deployment's certificates), signed by SIGNERS {pkKey pkCert kekKey
# kekCert} (the PK and KEK pairs; a rotation's are the old set's), with Microsoft's objects from
# MS; each file is verified against its signer's certificate before it is kept
export def write [dir: string, certs: record, signers: record, ms: string, epoch: int] {
  key-pair $signers.pkKey $signers.pkCert
  key-pair $signers.kekKey $signers.kekCert
  if (der $signers.pkCert) != (der $certs.pk) or (der $signers.kekCert) != (der $certs.kek) {
    error make {msg: $"($signers.pkCert) and ($signers.kekCert) sign, but the set enrols ($certs.pk) and ($certs.kek); a db rotation keeps the PK and KEK \(make-keys --reuse-pk-kek\)"}
  }
  let key = {PK: {key: $signers.pkKey cert: $signers.pkCert} KEK: {key: $signers.kekKey cert: $signers.kekCert}}
  for set in [[name ms]; [microsoft $ms] [golconda null]] {
    let p = (payloads $certs $set.ms)
    let out = $"($dir)/($set.name)"
    mkdir $out
    for v in ($variables | where {|v| $v.name in ($p | columns) }) {
      let s = ($key | get $v.signer)
      let file = $"($out)/($v.name).auth"
      auth $v.name $epoch ($p | get $v.name) $s.key $s.cert | save -f --raw $file
      if (verify $file $v.name $v.guid $s.cert) != ($p | get $v.name) {
        error make {msg: $"($file): the payload is not what was signed"}
      }
    }
    log $"secureboot/auth/($set.name): (ls $out | get name | path basename | str join ', ')"
  }
}

# require-set SET WHICH: the key set SET has secureboot/auth/WHICH (microsoft or golconda); a set
# without it is refused with the commands that add it, with SET's own path
export def require-set [set: string, which: string] {
  let set = ($set | path expand)
  let dir = $"($set)/secureboot/auth/($which)"
  if ($dir | path exists) {
    return
  }
  error make {msg: ([
    $"($dir) is missing: a Secure Boot image puts these enrolment files on its ESP."
    "Write them on the release host with the set's PK and KEK keys (a set without them gets a pair):"
    $"  scripts/make-keys --auth-only ($set)"
    "If secureboot/PK.key and KEK.key are in another directory (kept offline, or a db rotation), name it:"
    $"  scripts/make-keys --auth-only --reuse-pk-kek DIR ($set)"
    "(docs/reference/release.md)"
  ] | str join "\n")}
}

# check-set DIR CERTS: DIR (secureboot/auth/microsoft or golconda) holds PK.auth, KEK.auth and
# db.auth, and dbx.auth or not; each verifies against its signer's certificate (CERTS {pk kek}),
# PK.auth enrols CERTS.pk, KEK.auth begins with CERTS.kek and db.auth with CERTS.db (the image's
# db certificate). The files, in systemd-boot's order, are returned.
export def check-set [dir: string, certs: record]: nothing -> list<string> {
  let present = ($variables | where {|v| ($"($dir)/($v.name).auth" | path exists) })
  let names = ($present | get name)
  for n in [db KEK PK] {
    if not ($n in $names) {
      error make {msg: $"($dir)/($n).auth is missing: write the key set's enrolment files with scripts/make-keys --auth-only"}
    }
  }
  let signer = {PK: $certs.pk KEK: $certs.kek}
  for v in $present {
    let payload = (verify $"($dir)/($v.name).auth" $v.name $v.guid ($signer | get $v.signer))
    let first = ({PK: $certs.pk KEK: $certs.kek db: $certs.db} | get -o $v.name)
    if $first != null {
      if (first-x509 $payload) != (der $first) {
        error make {msg: $"($dir)/($v.name).auth does not enrol ($first | path basename) first"}
      }
    }
  }
  $present | each {|v| $"($dir)/($v.name).auth" }
}
