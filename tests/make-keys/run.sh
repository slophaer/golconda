#!/bin/sh
# scripts/make-keys: run it into a temporary directory and check what lib.mkImage and the
# firmware need: the layout in the script header, mode 0600 on every file and 0700 on every
# directory, the db certificate's extensions and validity, the key pairs matching, and the
# OpenPGP files. The refusals (relative path, non-empty directory) too. Run from anywhere with
# nix on PATH and a Nix daemon; scripts/lint runs it.
set -u
repo=$(dirname "$(dirname "$(dirname "$(realpath "$0")")")")
. "$repo/scripts/tools.sh"
# the same openssl and gpg make-keys runs, to look at what it made
TOOLS=$(tools_path "$repo" openssl gnupg) || {
  echo "make-keys test: cannot build the tools (packages: openssl gnupg)" >&2
  exit 1
}
PATH="$TOOLS:$PATH"
export OPENSSL_CONF=/dev/null

failures=0
fail() {
  echo "FAIL $1" >&2
  failures=$((failures + 1))
}
# check <name> <command...>: the command must succeed
check() {
  name=$1
  shift
  "$@" >/dev/null 2>&1 || fail "$name"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
keys=$tmp/keys

out=$("$repo/scripts/make-keys" "$keys" 2>"$tmp/stderr") || {
  cat "$tmp/stderr" >&2
  fail "make-keys exits 0"
  exit 1
}

# the layout: these files, and nothing else (in C order: upper case first)
auth="secureboot/auth/golconda/KEK.auth secureboot/auth/golconda/PK.auth secureboot/auth/golconda/db.auth secureboot/auth/microsoft/KEK.auth secureboot/auth/microsoft/PK.auth secureboot/auth/microsoft/db.auth secureboot/auth/microsoft/dbx.auth"
files="pcr/pcr.key pcr/pcr.pub release/index.key release/index.pgp secureboot/KEK.crt secureboot/KEK.key secureboot/PK.crt secureboot/PK.key $auth secureboot/db.crt secureboot/db.key"
found=$(cd "$keys" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')
[ "$found" = "$(printf '%s ' "$files")" ] || fail "layout: found: $found"

# modes
mode() { stat -c %a "$1"; }
[ "$(mode "$keys")" = 700 ] || fail "DIR is 0700 (is $(mode "$keys"))"
for d in secureboot pcr release secureboot/auth secureboot/auth/microsoft secureboot/auth/golconda; do
  [ "$(mode "$keys/$d")" = 700 ] || fail "$d/ is 0700 (is $(mode "$keys/$d"))"
done
for f in $files; do
  [ "$(mode "$keys/$f")" = 600 ] || fail "$f is 0600 (is $(mode "$keys/$f"))"
done

# the db certificate: self-signed X.509, the extensions of a firmware db entry, 3650 days
cert=$keys/secureboot/db.crt
text=$(openssl x509 -in "$cert" -noout -text) || fail "db.crt parses"
has() { printf '%s\n' "$text" | grep -qF -- "$1" || fail "db.crt has: $1"; }
has "CA:TRUE"
has "Digital Signature"
has "Certificate Sign"
has "CRL Sign"
has "Code Signing"
has "Subject Key Identifier"
printf '%s\n' "$text" | grep -A1 "Basic Constraints" | grep -qF critical || fail "basicConstraints is critical"
printf '%s\n' "$text" | grep -A1 "Key Usage" | head -n 2 | grep -qF critical || fail "keyUsage is critical"
openssl x509 -in "$cert" -noout -subject -issuer \
  | awk '{ sub(/^[a-z]+=/, ""); s[NR] = $0 } END { exit !(s[1] == s[2]) }' || fail "db.crt is self-signed"
check "db.crt lasts 3650 days" openssl x509 -in "$cert" -noout -checkend $((3649 * 86400))
check "db.crt not 3652 days" sh -c "! openssl x509 -in '$cert' -noout -checkend $((3652 * 86400))"
check "db.crt is PEM" grep -q "BEGIN CERTIFICATE" "$cert"

# the keys match their halves
[ "$(openssl x509 -in "$cert" -noout -pubkey)" = "$(openssl pkey -in "$keys/secureboot/db.key" -pubout)" ] \
  || fail "db.key matches db.crt"
[ "$(openssl pkey -in "$keys/pcr/pcr.key" -pubout)" = "$(cat "$keys/pcr/pcr.pub")" ] || fail "pcr.pub matches pcr.key"

# the PK and the KEK, for systemd-boot's enrolment (the signer writes loader/keys/auto): each a
# self-signed certificate of its own key, named by its role, and no key is another's
for k in PK KEK; do
  c=$keys/secureboot/$k.crt
  [ "$(openssl x509 -in "$c" -noout -pubkey)" = "$(openssl pkey -in "$keys/secureboot/$k.key" -pubout)" ] \
    || fail "$k.key matches $k.crt"
  openssl x509 -in "$c" -noout -subject | grep -qF "golconda deployment $k " || fail "$k.crt names its role"
  openssl x509 -in "$c" -noout -subject -issuer \
    | awk '{ sub(/^[a-z]+=/, ""); s[NR] = $0 } END { exit !(s[1] == s[2]) }' || fail "$k.crt is self-signed"
  check "$k.crt lasts 3650 days" openssl x509 -in "$c" -noout -checkend $((3649 * 86400))
  printf '%s\n' "$out" | grep -q "^$k.crt sha256 (DER): [0-9a-f]\{64\}$" || fail "report: $k.crt fingerprint"
done
# the enrolment files hold the set's certificates (lib/image/enrol.nu writes them, tests/sign/enrol-test.nu
# checks them field by field): each .auth holds the DER of the certificate it enrols
hex() { od -An -v -tx1 | tr -d ' \n'; }
holds() { # holds AUTH CERT: the DER of CERT is in AUTH
  case $(hex < "$1") in *"$(openssl x509 -in "$2" -outform der | hex)"*) return 0 ;; esac
  return 1
}
for s in microsoft golconda; do
  for v in PK KEK db; do
    holds "$keys/secureboot/auth/$s/$v.auth" "$keys/secureboot/$v.crt" || fail "auth/$s/$v.auth enrols $v.crt"
  done
done

pubs=$(for k in PK KEK db; do openssl x509 -in "$keys/secureboot/$k.crt" -noout -pubkey | sha256sum; done | sort -u | wc -l)
[ "$pubs" = 3 ] || fail "PK, KEK and db are three keys"

# the release key: armored secret, binary public, and a signature checks the way systemd-pull checks
head -n 1 "$keys/release/index.key" | grep -qF -- "-----BEGIN PGP PRIVATE KEY BLOCK-----" || fail "index.key is armored"
head -c 10 "$keys/release/index.pgp" | grep -qF -- "-----BEGIN" && fail "index.pgp is binary"
home=$tmp/g
mkdir -m 700 "$home"
printf 'x\n' > "$tmp/SHA256SUMS"
GNUPGHOME=$home gpg --batch --import "$keys/release/index.key" 2>/dev/null || fail "index.key imports"
GNUPGHOME=$home gpg --batch --detach-sign --output "$tmp/SHA256SUMS.gpg" "$tmp/SHA256SUMS" 2>/dev/null || fail "index.key signs"
home2=$tmp/g2
mkdir -m 700 "$home2"
GNUPGHOME=$home2 gpg --batch --no-default-keyring --keyring "$keys/release/index.pgp" --verify "$tmp/SHA256SUMS.gpg" "$tmp/SHA256SUMS" 2>/dev/null \
  || fail "index.pgp verifies a signature of index.key"
GNUPGHOME=$home gpgconf --kill gpg-agent 2>/dev/null
GNUPGHOME=$home2 gpgconf --kill gpg-agent 2>/dev/null

# the report names the fingerprints, and never key material
printf '%s\n' "$out" | grep -q '^db.crt sha256 (DER): [0-9a-f]\{64\}$' || fail "report: db.crt fingerprint"
printf '%s\n' "$out" | grep -q '^release key fingerprint: [0-9A-F]\{40\}$' || fail "report: release fingerprint"
printf '%s\n' "$out" | grep -qF -- "PRIVATE KEY" && fail "report prints key material"

# a db rotation: the new set keeps the old PK and KEK (copies of the certificates, no keys), and
# its enrolment files enrol its own db, signed by the old KEK
keys2=$tmp/keys2
"$repo/scripts/make-keys" --reuse-pk-kek "$keys" "$keys2" >"$tmp/out2" 2>"$tmp/stderr2" || {
  cat "$tmp/stderr2" >&2
  fail "make-keys --reuse-pk-kek exits 0"
}
for k in PK KEK; do
  [ ! -e "$keys2/secureboot/$k.key" ] || fail "rotation: no $k.key in the new set"
  cmp -s "$keys/secureboot/$k.crt" "$keys2/secureboot/$k.crt" || fail "rotation: $k.crt is the old set's"
done
cmp -s "$keys/secureboot/db.crt" "$keys2/secureboot/db.crt" && fail "rotation: a new db certificate"
holds "$keys2/secureboot/auth/microsoft/db.auth" "$keys2/secureboot/db.crt" || fail "rotation: db.auth enrols the new db.crt"
cmp -s "$keys/secureboot/auth/microsoft/KEK.auth" "$keys2/secureboot/auth/microsoft/KEK.auth" ||
  holds "$keys2/secureboot/auth/microsoft/KEK.auth" "$keys/secureboot/KEK.crt" || fail "rotation: KEK.auth enrols the old KEK"
grep -qF "copies of $keys" "$tmp/out2" || fail "rotation: the report names the old set"
"$repo/scripts/make-keys" --reuse-pk-kek "$keys2" "$tmp/keys3" >/dev/null 2>&1 && fail "--reuse-pk-kek needs a set with PK.key and KEK.key"

# refusals
"$repo/scripts/make-keys" relative/dir >/dev/null 2>&1 && fail "relative DIR is refused"
"$repo/scripts/make-keys" "$keys" >/dev/null 2>&1 && fail "non-empty DIR is refused"
"$repo/scripts/make-keys" >/dev/null 2>&1 && fail "no argument is refused"

if [ "$failures" -ne 0 ]; then
  echo "make-keys test: $failures failed" >&2
  exit 1
fi
echo "make-keys test: ok"
