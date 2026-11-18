#!/bin/sh
# scripts/make-keys into a temporary directory: the layout of docs/reference/release.md (the PK
# and KEK keys in DIR.private), mode 0600 on every file and 0700 on every directory, the db
# certificate's extensions and validity,
# the key pairs matching and the OpenPGP files; a relative DIR; the refusals (non-empty directory,
# git work tree, unknown option). Needs nix on PATH and a Nix daemon; scripts/lint runs it.
set -u
repo=$(dirname "$(dirname "$(dirname "$(realpath "$0")")")")
. "$repo/scripts/tools.sh"
# the same openssl and gpg make-keys runs, to look at what it made
TOOLS=$(tools_path "$repo" openssl gnupg) || {
  echo "make-keys test: cannot build the tools (packages: openssl gnupg)" >&2
  exit 1
}
PATH="$TOOLS:$PATH"

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
files="pcr/pcr.key pcr/pcr.pub release/index.key release/index.pgp secureboot/KEK.crt secureboot/PK.crt $auth secureboot/db.crt secureboot/db.key"
found=$(cd "$keys" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')
[ "$found" = "$(printf '%s ' "$files")" ] || fail "layout: found: $found"
# the PK and KEK keys, for offline media: in DIR.private, and nothing else there
private=$keys.private
found=$(cd "$private" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')
[ "$found" = "KEK.key PK.key " ] || fail "DIR.private holds PK.key and KEK.key: found: $found"
printf '%s\n' "$out" | grep -qx "move $private to offline media: only scripts/make-keys --auth-only and --reuse-pk-kek read it" ||
  fail "the report names DIR.private and offline media"

# modes
mode() { stat -c %a "$1"; }
[ "$(mode "$keys")" = 700 ] || fail "DIR is 0700 (is $(mode "$keys"))"
[ "$(mode "$private")" = 700 ] || fail "DIR.private is 0700 (is $(mode "$private"))"
for k in PK KEK; do
  [ "$(mode "$private/$k.key")" = 600 ] || fail "$k.key is 0600 (is $(mode "$private/$k.key"))"
done
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
  [ "$(openssl x509 -in "$c" -noout -pubkey)" = "$(openssl pkey -in "$private/$k.key" -pubout)" ] \
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
# the clock floor: a machine's clock is at least 00:00 UTC of the release date, and sign-index
# (lib/image/disk.nu) signs at that time, or one second after the key's creation when that is
# later. The key is made at 00:00 UTC the day before, so a release of today signs at the floor,
# and gpg at the floor takes it.
today=$(($(date -u +%s) / 86400 * 86400))
created=$(gpg --batch --with-colons --show-keys "$keys/release/index.pgp" | awk -F: '$1 == "pub" { print $6; exit }')
[ "$created" = $((today - 86400)) ] || fail "the release key is made at 00:00 UTC the day before (is $created)"
at=$today
[ "$at" -gt "${created:-0}" ] || at=$((created + 1))
GNUPGHOME=$home gpg --batch --yes --faked-system-time "$at!" --detach-sign --output "$tmp/floor.gpg" "$tmp/SHA256SUMS" 2>/dev/null ||
  fail "index.key signs at the clock floor"
GNUPGHOME=$home2 gpg --batch --faked-system-time "$today!" --no-default-keyring --keyring "$keys/release/index.pgp" \
  --verify "$tmp/floor.gpg" "$tmp/SHA256SUMS" 2>/dev/null || fail "a release of today verifies at the clock floor"
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
[ ! -e "$keys2.private" ] || fail "rotation: no DIR.private for the new set"
for k in PK KEK; do
  cmp -s "$keys/secureboot/$k.crt" "$keys2/secureboot/$k.crt" || fail "rotation: $k.crt is the old set's"
done
cmp -s "$keys/secureboot/db.crt" "$keys2/secureboot/db.crt" && fail "rotation: a new db certificate"
holds "$keys2/secureboot/auth/microsoft/db.auth" "$keys2/secureboot/db.crt" || fail "rotation: db.auth enrols the new db.crt"
cmp -s "$keys/secureboot/auth/microsoft/KEK.auth" "$keys2/secureboot/auth/microsoft/KEK.auth" ||
  holds "$keys2/secureboot/auth/microsoft/KEK.auth" "$keys/secureboot/KEK.crt" || fail "rotation: KEK.auth enrols the old KEK"
grep -qF "copies of $keys" "$tmp/out2" || fail "rotation: the report names the old set"
# the release key cannot change: the new set has the old set's
for f in index.key index.pgp; do
  cmp -s "$keys/release/$f" "$keys2/release/$f" || fail "rotation: release/$f is the old set's"
done
[ "$(grep '^release key fingerprint:' "$tmp/out2")" = "$(printf '%s\n' "$out" | grep '^release key fingerprint:')" ] ||
  fail "rotation: the report names the old release key"
"$repo/scripts/make-keys" --reuse-pk-kek "$keys2" "$tmp/keys3" >/dev/null 2>&1 && fail "--reuse-pk-kek needs OLD.private with PK.key and KEK.key"

# --auth-only: a set without enrolment files gets them, and a PK and a KEK of its own; the command is the one the signer's refusal names (tests/sign/enrol-test.nu)
keys4=$tmp/keys4
cp -R "$keys" "$keys4"
rm -r "$keys4/secureboot/auth" "$keys4/secureboot/PK.crt" "$keys4/secureboot/KEK.crt"
"$repo/scripts/make-keys" --auth-only "$keys4" >"$tmp/out4" 2>"$tmp/stderr4" || {
  cat "$tmp/stderr4" >&2
  fail "make-keys --auth-only exits 0"
}
[ "$(mode "$keys4.private")" = 700 ] || fail "--auth-only: DIR.private is 0700"
for k in PK KEK; do
  [ -f "$keys4.private/$k.key" ] || fail "--auth-only: makes DIR.private/$k.key for a set without one"
  [ "$(mode "$keys4.private/$k.key")" = 600 ] || fail "--auth-only: $k.key is 0600"
  [ ! -e "$keys4/secureboot/$k.key" ] || fail "--auth-only: no $k.key in the set"
done
for s in microsoft golconda; do
  for v in PK KEK db; do
    holds "$keys4/secureboot/auth/$s/$v.auth" "$keys4/secureboot/$v.crt" || fail "--auth-only: auth/$s/$v.auth enrols $v.crt"
  done
done
[ -f "$keys4/secureboot/auth/microsoft/dbx.auth" ] || fail "--auth-only: auth/microsoft/dbx.auth"
cmp -s "$keys/secureboot/db.crt" "$keys4/secureboot/db.crt" || fail "--auth-only: keeps the db certificate"
# again, with the keys there: the files are written anew (a newer dbx), the PK and KEK stay
pk4=$(sha256sum < "$keys4/secureboot/PK.crt")
"$repo/scripts/make-keys" --auth-only "$keys4" >/dev/null 2>&1 || fail "make-keys --auth-only runs again"
[ "$(sha256sum < "$keys4/secureboot/PK.crt")" = "$pk4" ] || fail "--auth-only again: keeps the PK"
# a set whose PK and KEK keys are elsewhere (offline, or a rotation): --reuse-pk-kek names them
rm -r "$keys2/secureboot/auth"
"$repo/scripts/make-keys" --auth-only --reuse-pk-kek "$keys" "$keys2" >/dev/null 2>"$tmp/stderr5" || {
  cat "$tmp/stderr5" >&2
  fail "make-keys --auth-only --reuse-pk-kek exits 0"
}
holds "$keys2/secureboot/auth/microsoft/db.auth" "$keys2/secureboot/db.crt" || fail "--auth-only --reuse-pk-kek: db.auth"
[ ! -e "$keys2.private" ] || fail "--auth-only --reuse-pk-kek: no DIR.private for the set"
"$repo/scripts/make-keys" --auth-only "$keys2" >/dev/null 2>"$tmp/stderr6" && fail "--auth-only refuses a set with PK.crt but no DIR.private"
grep -qF -- "--reuse-pk-kek" "$tmp/stderr6" || fail "--auth-only without the keys names --reuse-pk-kek"
"$repo/scripts/make-keys" --auth-only --reuse-pk-kek "$keys4" "$keys2" >/dev/null 2>&1 &&
  fail "--auth-only --reuse-pk-kek refuses another PK than the set's"
"$repo/scripts/make-keys" --auth-only "$tmp/nothing" >/dev/null 2>&1 && fail "--auth-only needs a key set"

# a relative DIR is made absolute, for both modes: the report names the absolute path
mkdir "$tmp/cwd"
(cd "$tmp/cwd" && "$repo/scripts/make-keys" rel/keys) >"$tmp/out-rel" 2>&1 || fail "relative DIR: make-keys exits 0"
[ -f "$tmp/cwd/rel/keys/secureboot/db.crt" ] || fail "relative DIR: the set is made under the working directory"
[ -f "$tmp/cwd/rel/keys.private/PK.key" ] || fail "relative DIR: DIR.private is made beside it"
grep -qF "deployment key set: $tmp/cwd/rel/keys" "$tmp/out-rel" || fail "relative DIR: the report names the absolute path"
(cd "$tmp/cwd" && "$repo/scripts/make-keys" --auth-only rel/keys) >/dev/null 2>&1 || fail "relative DIR: --auth-only exits 0"

# refusals
"$repo/scripts/make-keys" "$keys" >/dev/null 2>&1 && fail "non-empty DIR is refused"
mkdir "$tmp/keys8.private"
touch "$tmp/keys8.private/PK.key"
"$repo/scripts/make-keys" "$tmp/keys8" >/dev/null 2>&1 && fail "a non-empty DIR.private is refused"
[ ! -e "$tmp/keys8" ] || fail "a non-empty DIR.private makes nothing"
"$repo/scripts/make-keys" >/dev/null 2>&1 && fail "no argument is refused"
# --help prints the header and exits 0; an unknown option names itself and exits 2
"$repo/scripts/make-keys" --help >"$tmp/help" 2>&1 || fail "--help exits 0"
grep -q '^make-keys \[--auth-only\]' "$tmp/help" || fail "--help prints the usage: $(cat "$tmp/help")"
"$repo/scripts/make-keys" --bogus "$tmp/keys9" >/dev/null 2>"$tmp/stderr9"
[ $? = 2 ] || fail "an unknown option exits 2"
grep -qx 'make-keys: unknown option --bogus' "$tmp/stderr9" || fail "an unknown option is named: $(cat "$tmp/stderr9")"
[ ! -e "$tmp/keys9" ] || fail "an unknown option makes nothing"
# a directory in a git work tree: a file there can reach the store with the checkout, so a set
# made there, or kept there (--auth-only reads its PK and KEK keys), is refused; nothing is made
git init -q "$tmp/checkout"
"$repo/scripts/make-keys" "$tmp/checkout/site/keys" >/dev/null 2>"$tmp/stderr-git" &&
  fail "DIR in a git work tree is refused"
grep -q 'git work tree' "$tmp/stderr-git" || fail "the refusal names the git work tree: $(cat "$tmp/stderr-git")"
[ -e "$tmp/checkout/site" ] && fail "nothing is made in the git work tree"
cp -R "$keys" "$tmp/checkout/keys"
cp -R "$private" "$tmp/checkout/keys.private"
"$repo/scripts/make-keys" --auth-only "$tmp/checkout/keys" >/dev/null 2>&1 &&
  fail "--auth-only refuses a set in a git work tree"

if [ "$failures" -ne 0 ]; then
  echo "make-keys test: $failures failed" >&2
  exit 1
fi
echo "make-keys test: ok"
