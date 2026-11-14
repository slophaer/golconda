#!/bin/sh
# golconda-esp-credentials (modules/base) without a machine: GOLCONDA_ESP points it at a scratch
# ESP. Every *.cred systemd-stub passes on goes, loader/credentials/ and a UKI's .extra.d/, and
# nothing else: not the UKIs, not an addon or sysext beside them, not loader.conf.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
PROGRAM=$ROOT/modules/base/golconda-esp-credentials
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ERRORS=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

ESP=$WORK/esp
mkdir -p "$ESP/loader/credentials" "$ESP/EFI/Linux/boot-test_20261101.1.efi.extra.d"
for f in loader/loader.conf EFI/Linux/boot-test_20261101.1.efi \
  loader/credentials/ssh.authorized_keys.root.cred loader/credentials/system.hostname.cred \
  loader/credentials/firstboot.hostname.cred \
  EFI/Linux/boot-test_20261101.1.efi.extra.d/planted.cred \
  EFI/Linux/boot-test_20261101.1.efi.extra.d/debug.addon.efi; do
  printf 'x' > "$ESP/$f"
done

GOLCONDA_ESP=$ESP sh "$PROGRAM" > "$WORK/out" 2>&1
cat "$WORK/out"
check "every credential is gone" \
  '[ -z "$(ls "$ESP"/loader/credentials/*.cred "$ESP"/EFI/Linux/*.extra.d/*.cred 2>/dev/null)" ]'
check "the rest of the ESP stays" \
  '[ -f "$ESP/loader/loader.conf" ] && [ -f "$ESP/EFI/Linux/boot-test_20261101.1.efi" ] && [ -f "$ESP/EFI/Linux/boot-test_20261101.1.efi.extra.d/debug.addon.efi" ]'
check "each removal is logged" \
  'grep -qx "removed loader/credentials/ssh.authorized_keys.root.cred from the ESP" "$WORK/out" && grep -qx "removed EFI/Linux/boot-test_20261101.1.efi.extra.d/planted.cred from the ESP" "$WORK/out" && grep -qx "4 bootstrap credential(s) removed from the ESP" "$WORK/out"'

GOLCONDA_ESP=$ESP sh "$PROGRAM" > "$WORK/out" 2>&1
check "a later boot finds nothing to remove" 'grep -qx "0 bootstrap credential(s) removed from the ESP" "$WORK/out"'

rm -rf "$ESP/loader/credentials"
GOLCONDA_ESP=$ESP sh "$PROGRAM" > "$WORK/out" 2>&1
check "an ESP without loader/credentials is fine" 'grep -qx "0 bootstrap credential(s) removed from the ESP" "$WORK/out"'

if [ "$ERRORS" -gt 0 ]; then
  echo "$ERRORS check(s) failed"
  exit 1
fi
echo "all checks passed"
