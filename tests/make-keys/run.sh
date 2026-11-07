#!/bin/sh
# scripts/make-keys: run it into a temporary directory and check what lib.mkImage and the
# firmware need: the layout in the script header, mode 0600 on every file and 0700 on every
# directory, the db certificate's extensions and validity, the key pairs matching, and the
# OpenPGP files. The refusals (relative path, non-empty directory) too. Run from anywhere with
# nix on PATH and the build daemon in NIX_REMOTE (a chroot store: GOLCONDA_STORE_ROOT);
# scripts/lint runs it.
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

# the layout: these files, and nothing else
files="pcr/pcr.key pcr/pcr.pub release/index.key release/index.pgp secureboot/db.crt secureboot/db.key"
found=$(cd "$keys" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')
[ "$found" = "$(printf '%s ' "$files")" ] || fail "layout: found: $found"

# modes
mode() { stat -c %a "$1"; }
[ "$(mode "$keys")" = 700 ] || fail "DIR is 0700 (is $(mode "$keys"))"
for d in secureboot pcr release; do
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

# refusals
"$repo/scripts/make-keys" relative/dir >/dev/null 2>&1 && fail "relative DIR is refused"
"$repo/scripts/make-keys" "$keys" >/dev/null 2>&1 && fail "non-empty DIR is refused"
"$repo/scripts/make-keys" >/dev/null 2>&1 && fail "no argument is refused"

if [ "$failures" -ne 0 ]; then
  echo "make-keys test: $failures failed" >&2
  exit 1
fi
echo "make-keys test: ok"
