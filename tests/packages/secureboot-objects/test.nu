# Microsoft's Secure Boot objects as lib/image/enrol.nu reads them. Each certificate is the one
# its name says: the subject's CN, and the SHA-1 fingerprint that systemd's loader.conf(5) lists
# for it (v262.1; the Option ROM CA is not in that list, its fingerprint is the pinned file's).
# The revocation list is an EFI_VARIABLE_AUTHENTICATION_2 with a PKCS#7 signature, followed by
# signature lists of SHA-256 hashes (EFI_CERT_SHA256_GUID), at least the 443 of 1.7.2.
use checks.nu *
let s = $"($env.pkg)/share/secureboot-objects"
let openssl = $"($env.openssl)/bin/openssl"
$env.OPENSSL_CONF = "/dev/null"

let certs = [
  [file cn sha1];
  [KEK/microsoft-kek-ca-2011.der "Microsoft Corporation KEK CA 2011" "31590BFD89C9D74ED087DFAC66334B3931254B30"]
  [KEK/microsoft-kek-2k-ca-2023.der "Microsoft Corporation KEK 2K CA 2023" "459AB6FB5E284D272D5E3E6ABC8ED663829D632B"]
  [db/microsoft-uefi-ca-2011.der "Microsoft Corporation UEFI CA 2011" "46DEF63B5CE61CF8BA0DE2E6639C1019D0ED14F3"]
  [db/microsoft-uefi-ca-2023.der "Microsoft UEFI CA 2023" "B5EEB4A6706048073F0ED296E7F580A790B59EAA"]
  [db/microsoft-option-rom-uefi-ca-2023.der "Microsoft Option ROM UEFI CA 2023" "3FB39E2B8BD183BF9E4594E72183CA60AFCD4277"]
  [db/windows-production-pca-2011.der "Microsoft Windows Production PCA 2011" "580A6F4CC4E4B669B9EBDC1B2B3E087B80D0678D"]
  [db/windows-uefi-ca-2023.der "Windows UEFI CA 2023" "45A0FA32604773C82433C3B7D59E7466B3AC0C67"]
]
for c in $certs {
  let f = $"($s)/($c.file)"
  let subject = (^$openssl x509 -inform DER -in $f -noout -subject -nameopt multiline | lines | where {|l| $l =~ 'commonName' } | first | split row "=" | last | str trim)
  assert $"($c.file): CN ($subject)" ($subject == $c.cn)
  let fp = (^$openssl x509 -inform DER -in $f -noout -fingerprint -sha1 | str trim | split row "=" | last | str replace -a ":" "")
  assert $"($c.file): SHA-1 ($fp)" ($fp == $c.sha1)
}

let d = (open --raw $"($s)/dbx/DBXUpdate-amd64.bin" | into binary)
let len = ($d | bytes at 16..<20 | into int -e little)
assert "dbx: WIN_CERT_TYPE_EFI_GUID, revision 0x0200" (($d | bytes at 20..<24) == 0x[00 02 f1 0e])
assert "dbx: a PKCS#7 signature" (($d | bytes at 24..<40) == 0x[9d d2 af 4a df 68 ee 49 8a a9 34 7d 37 56 65 a7])
mut off = 16 + $len
mut hashes = 0
while $off < ($d | bytes length) {
  let list = ($d | bytes at $off..<($off + 28))
  assert "dbx: a list of EFI_CERT_SHA256 entries" (($list | bytes at 0..<16) == 0x[26 16 c4 c1 4c 50 92 40 ac a9 41 f9 36 93 43 28])
  let size = ($list | bytes at 16..<20 | into int -e little)
  let entry = ($list | bytes at 24..<28 | into int -e little)
  assert "dbx: entries of an owner GUID and a SHA-256" ($entry == 48)
  $hashes = $hashes + (($size - 28) / $entry | into int)
  $off = $off + $size
}
assert $"dbx: ($hashes) hashes, the lists fill the file" ($off == ($d | bytes length) and $hashes >= 443)
done
