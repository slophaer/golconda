# Tests for the Secure Boot enrolment files (lib/image/enrol.nu): what scripts/make-keys writes
# into a key set (secureboot/auth/{microsoft,golconda}) and what the signer checks before it
# copies a set onto the ESP. Two key sets are made here, A and B, and B's db is rotated: it keeps
# A's PK and KEK.
#
# Run from the repo root with openssl on PATH and GOLCONDA_SECUREBOOT_OBJECTS naming
# packages/secureboot-objects' share/secureboot-objects (checks.image-signer runs it so):
#   nu --no-config-file --include-path lib/image tests/sign/enrol.nu

use enrol.nu

$env.OPENSSL_CONF = "/dev/null"
let tmp = (mktemp -d -t "golconda-enrol-test-XXXXXX")
let ms = $env.GOLCONDA_SECUREBOOT_OBJECTS
const global = "8be4df61-93ca-11d2-aa0d-00e098032b8c"
const secdb = "d719b2cb-3d3a-4596-a3bc-dad00e67656f"

def ok [name: string] { print $"ok: ($name)" }

# BODY must fail with a message that contains WANT
def fails [name: string, want: string, body: closure] {
  let msg = (try { do $body; "no error" } catch {|e| $e.msg })
  if not ($msg | str contains $want) {
    error make {msg: $"($name): expected an error with '($want)', got '($msg)'"}
  }
  ok $name
}

def cert [dir: string, k: string, cn: string] {
  ^openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj $"/CN=($cn) ($k)/" -keyout $"($dir)/secureboot/($k).key" -out $"($dir)/secureboot/($k).crt" e> /dev/null
}
def set-of [dir: string]: nothing -> record {
  {pk: $"($dir)/secureboot/PK.crt" kek: $"($dir)/secureboot/KEK.crt" db: $"($dir)/secureboot/db.crt"}
}
def signers-of [dir: string]: nothing -> record {
  {pkKey: $"($dir)/secureboot/PK.key" pkCert: $"($dir)/secureboot/PK.crt" kekKey: $"($dir)/secureboot/KEK.key" kekCert: $"($dir)/secureboot/KEK.crt"}
}
def der-of [file: string]: nothing -> binary {
  let form = (if ($file | str ends-with ".der") { "DER" } else { "PEM" })
  let out = (mktemp -t "golconda-der-XXXXXX")
  ^openssl x509 -inform $form -in $file -outform DER -out $out
  let b = (open --raw $out | into binary)
  rm $out
  $b
}
# the signature list of one X.509 entry, field by field: EFI_CERT_X509_GUID, the sizes, the owner
def x509-list [file: string, owner: binary]: nothing -> binary {
  let d = (der-of $file)
  let n = ($d | bytes length)
  [
    0x[a1 59 c0 a5 e4 94 a7 4a 87 b5 ab 15 5c 2b f0 72]
    (44 + $n | into binary | bytes at 0..<4)
    0x[00 00 00 00]
    (16 + $n | into binary | bytes at 0..<4)
    $owner
    $d
  ] | bytes collect
}
const golconda_owner = 0x[22 c5 b1 30 c2 c5 0b 4f b8 05 31 f1 d1 55 15 4c]
const microsoft_owner = 0x[bd 9a fa 77 59 03 32 4d bd 60 28 f4 e7 8f 78 4b]

let a = $"($tmp)/a"
let b = $"($tmp)/b"
for s in [[dir name]; [$a "Test A"] [$b "Test B"]] {
  mkdir $"($s.dir)/secureboot"
  for k in [PK KEK db] { cert $s.dir $k $s.name }
}
let epoch = 1793404801
enrol write $"($a)/secureboot/auth" (set-of $a) (signers-of $a) $ms $epoch
let names = {|d| ls $d | get name | path basename | sort }
if (do $names $"($a)/secureboot/auth/microsoft") != [KEK.auth PK.auth db.auth dbx.auth] { error make {msg: "auth/microsoft is not PK, KEK, db, dbx"} }
if (do $names $"($a)/secureboot/auth/golconda") != [KEK.auth PK.auth db.auth] { error make {msg: "auth/golconda is not PK, KEK, db"} }
ok "make-keys' step writes auth/microsoft (PK, KEK, db, dbx) and auth/golconda (PK, KEK, db)"

# the payloads, list by list: ours first (Golconda's owner), then Microsoft's (Microsoft's owner)
let m = $"($a)/secureboot/auth/microsoft"
let g = $"($a)/secureboot/auth/golconda"
let pkc = $"($a)/secureboot/PK.crt"
let kekc = $"($a)/secureboot/KEK.crt"
let pk_list = (enrol verify $"($m)/PK.auth" PK $global $pkc)
let kek_list = (enrol verify $"($m)/KEK.auth" KEK $global $pkc)
let db_list = (enrol verify $"($m)/db.auth" db $secdb $kekc)
let dbx_list = (enrol verify $"($m)/dbx.auth" dbx $secdb $kekc)
ok "PK.auth and KEK.auth verify against the PK, db.auth and dbx.auth against the KEK"
if $pk_list != (x509-list $pkc $golconda_owner) { error make {msg: "PK.auth does not enrol PK.crt alone"} }
let want_kek = ([(x509-list $kekc $golconda_owner) (x509-list $"($ms)/KEK/microsoft-kek-ca-2011.der" $microsoft_owner) (x509-list $"($ms)/KEK/microsoft-kek-2k-ca-2023.der" $microsoft_owner)] | bytes collect)
if $kek_list != $want_kek { error make {msg: "KEK.auth is not KEK.crt, Microsoft KEK CA 2011, KEK 2K CA 2023"} }
let want_db = ([(x509-list $"($a)/secureboot/db.crt" $golconda_owner) (x509-list $"($ms)/db/microsoft-uefi-ca-2011.der" $microsoft_owner) (x509-list $"($ms)/db/microsoft-uefi-ca-2023.der" $microsoft_owner) (x509-list $"($ms)/db/microsoft-option-rom-uefi-ca-2023.der" $microsoft_owner)] | bytes collect)
if $db_list != $want_db { error make {msg: "db.auth is not db.crt and Microsoft's three UEFI CAs"} }
for w in [windows-production-pca-2011.der windows-uefi-ca-2023.der] {
  if ($db_list | bytes index-of (der-of $"($ms)/db/($w)")) >= 0 { error make {msg: $"db.auth holds ($w)"} }
}
let ms_dbx = (open --raw $"($ms)/dbx/DBXUpdate-amd64.bin" | into binary)
let ms_len = ($ms_dbx | bytes at 16..<20 | into int -e little)
if $dbx_list != ($ms_dbx | bytes at (16 + $ms_len)..) { error make {msg: "dbx.auth is not Microsoft's revocation lists"} }
ok "microsoft: PK; KEK ours + KEK CA 2011 + KEK 2K CA 2023; db ours + UEFI CA 2011, 2023, Option ROM 2023, no Windows CA; dbx Microsoft's"
if (enrol verify $"($g)/KEK.auth" KEK $global $pkc) != (x509-list $kekc $golconda_owner) { error make {msg: "golconda KEK.auth is not KEK.crt alone"} }
if (enrol verify $"($g)/db.auth" db $secdb $kekc) != (x509-list $"($a)/secureboot/db.crt" $golconda_owner) { error make {msg: "golconda db.auth is not db.crt alone"} }
ok "golconda: PK, KEK and db hold the key set's certificates alone"

# the header: EFI_TIME of the epoch (2026-10-31 00:00:01 UTC), WIN_CERT_TYPE_EFI_GUID, PKCS#7, and
# a SignedData without a ContentInfo (a SEQUENCE whose first element is the version, INTEGER 1)
let head = (open --raw $"($m)/db.auth" | into binary)
if ($head | bytes at 0..<16) != 0x[ea 07 0a 1f 00 00 01 00 00 00 00 00 00 00 00 00] { error make {msg: "db.auth: EFI_TIME is not the epoch's"} }
if ($head | bytes at 20..<24) != 0x[00 02 f1 0e] { error make {msg: "db.auth: not wRevision 0x0200, WIN_CERT_TYPE_EFI_GUID"} }
if ($head | bytes at 24..<40) != 0x[9d d2 af 4a df 68 ee 49 8a a9 34 7d 37 56 65 a7] { error make {msg: "db.auth: CertType is not EFI_CERT_TYPE_PKCS7_GUID"} }
if ($head | bytes at 40..<41) != 0x[30] or ($head | bytes at 44..<47) != 0x[02 01 01] { error make {msg: "db.auth: the PKCS#7 is not a bare SignedData"} }
ok "the header is EFI_VARIABLE_AUTHENTICATION_2 with the epoch's time and a bare SignedData"

fails "KEK.auth is not signed by the KEK" "does not verify" {||
  enrol verify $"($m)/KEK.auth" KEK $global $kekc
}
fails "db.auth does not verify against another set's KEK" "does not verify" {||
  enrol verify $"($m)/db.auth" db $secdb $"($b)/secureboot/KEK.crt"
}
fails "db.auth does not verify as another variable" "does not verify" {||
  enrol verify $"($m)/db.auth" KEK $global $kekc
}
open --raw $"($m)/db.auth" | into binary | bytes add 0x[00] --end | save -f --raw $"($tmp)/db-tampered.auth"
fails "a changed payload does not verify" "does not verify" {||
  enrol verify $"($tmp)/db-tampered.auth" db $secdb $kekc
}

let hashes = {|d| ls $d | sort-by name | each {|f| open --raw $f.name | hash sha256 } }
let first = (do $hashes $m)
enrol write $"($a)/secureboot/auth" (set-of $a) (signers-of $a) $ms $epoch
if (do $hashes $m) != $first { error make {msg: "a second write differs: not deterministic"} }
ok "the files are deterministic for one epoch"

# the signer's check: each set passes against its own certificates and the image's db
if (enrol check-set $m (set-of $a) | path basename) != [db.auth dbx.auth KEK.auth PK.auth] { error make {msg: "check-set microsoft: not db, dbx, KEK, PK"} }
if (enrol check-set $g (set-of $a) | path basename) != [db.auth KEK.auth PK.auth] { error make {msg: "check-set golconda: not db, KEK, PK"} }
ok "the signer's check passes both sets, in systemd-boot's order (db, dbx, KEK, PK)"
fails "the signer refuses a set for another db certificate" "does not enrol db.crt first" {||
  enrol check-set $m ((set-of $a) | upsert db $"($b)/secureboot/db.crt")
}
fails "the signer refuses a set signed by another KEK" "does not verify" {||
  enrol check-set $m ((set-of $a) | upsert kek $"($b)/secureboot/KEK.crt")
}
fails "the signer refuses a set without db.auth" "db.auth is missing" {||
  enrol check-set $"($tmp)/none" (set-of $a)
}
# a key set made before make-keys wrote the files: the refusal names the commands that add them,
# with this set's path, for keys in the set and for keys elsewhere
let old_set = $"($tmp)/old-set"
mkdir $"($old_set)/secureboot"
let msg = (try { enrol require-set $old_set microsoft; "no error" } catch {|e| $e.msg })
let set_abs = ($old_set | path expand)
for want in [
  $"($set_abs)/secureboot/auth/microsoft is missing"
  $"scripts/make-keys --auth-only ($set_abs)"
  $"scripts/make-keys --auth-only --reuse-pk-kek DIR ($set_abs)"
  "secureboot/PK.key and KEK.key"
] {
  if not ($msg | str contains $want) { error make {msg: $"the refusal does not say '($want)': ($msg)"} }
}
ok "a set without enrolment files is refused with the make-keys commands that add them"
enrol require-set $a microsoft
ok "a set with them passes"

# a db rotation: B's db with A's PK and KEK, signed by A's keys; B holds no PK or KEK key
for k in [PK KEK] {
  rm $"($b)/secureboot/($k).key"
  ^cp -f $"($a)/secureboot/($k).crt" $"($b)/secureboot/($k).crt"
}
enrol write $"($b)/secureboot/auth" (set-of $b) (signers-of $a) $ms $epoch
let rotated = (enrol verify $"($b)/secureboot/auth/microsoft/db.auth" db $secdb $kekc)
if ($rotated | bytes at 0..<((x509-list $"($b)/secureboot/db.crt" $golconda_owner) | bytes length)) != (x509-list $"($b)/secureboot/db.crt" $golconda_owner) { error make {msg: "the rotated db.auth does not enrol B's db"} }
enrol check-set $"($b)/secureboot/auth/microsoft" (set-of $b) | ignore
ok "a rotation: B's db.auth enrols B's db, signed by A's KEK, and B needs no PK or KEK key"
fails "a PK that is not the set's own cannot sign it" "not the ones the set enrols" {||
  enrol write $"($tmp)/auth" (set-of $b) ((signers-of $a) | upsert pkCert $"($b)/secureboot/db.crt" | upsert pkKey $"($b)/secureboot/db.key") $ms $epoch
}
fails "a key that is not its certificate's is refused" "is not the key of" {||
  enrol write $"($tmp)/auth" (set-of $a) ((signers-of $a) | upsert kekKey $"($a)/secureboot/PK.key") $ms $epoch
}

rm -rf $tmp
print "all enrolment tests passed"
