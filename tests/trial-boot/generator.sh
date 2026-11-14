#!/bin/sh
# The trial boot generator (modules/base/golconda-trial-boot-generator) without a machine:
# GOLCONDA_TRIAL_BOOT_ROOT points it at a scratch tree with a fake efivarfs, /etc and /dev/kmsg.
# The drop-in must appear on a counted boot that had a try left, and nowhere else: not on a
# blessed boot, not on an entry that had no try left, not in the initrd, not for a name without
# a counter (docs/design/boot.md, "Trial boot").
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ERRORS=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# the generator as /base renders it: @tries@ is image/boot-counting.nix's 3 + 0
GEN=$WORK/generator
while IFS= read -r line; do
  case $line in
    'tries=@tries@') echo 'tries=3' ;;
    *) printf '%s\n' "$line" ;;
  esac
done < "$ROOT/modules/base/golconda-trial-boot-generator" > "$GEN"

VAR=sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
DROPIN=boot-complete.target.d/golconda-trial-boot.conf

# run CASE [PATH]: a fresh root, LoaderBootCountPath set to PATH (4 bytes of attributes, then
# UTF-16LE) unless PATH is empty, and the generator's normal directory at $WORK/CASE/out
run() {
  r=$WORK/$1
  mkdir -p "$r/sys/firmware/efi/efivars" "$r/etc" "$r/dev" "$r/out"
  : > "$r/dev/kmsg"
  if [ -n "${2:-}" ]; then
    {
      printf '\007\000\000\000'
      p=$2
      while [ -n "$p" ]; do
        c=${p%"${p#?}"}
        p=${p#?}
        printf '%s\000' "$c"
      done
      printf '\000\000'
    } > "$r/$VAR"
  fi
  GOLCONDA_TRIAL_BOOT_ROOT=$r sh "$GEN" "$r/out" "$r/early" "$r/late"
}
on_trial() { [ -L "$WORK/$1/out/$DROPIN" ] && [ "$(readlink "$WORK/$1/out/$DROPIN")" = /usr/lib/golconda/trial-boot.conf ]; }
no_dropin() { [ -z "$(ls -A "$WORK/$1/out")" ]; }
logged() { grep -q "$2" "$WORK/$1/dev/kmsg"; }

run blessed ""
check "a blessed boot (no LoaderBootCountPath) gets no drop-in and logs nothing" \
  'no_dropin blessed && [ ! -s "$WORK/blessed/dev/kmsg" ]'

run try1 '\EFI\Linux\boot-test_20261101.1+2-1.efi'
check "the first try (+2-1) is on trial" 'on_trial try1 && logged try1 "boot-test_20261101.1+2-1.efi is on trial"'

run try3 '\EFI\Linux\boot-test_20261101.1+0-3.efi'
check "the last try (+0-3) is on trial" 'on_trial try3'

run exhausted '\EFI\Linux\boot-test_20261101.1+0-4.efi'
check "an entry that had no try left (+0-4) gets no drop-in" \
  'no_dropin exhausted && logged exhausted "had no try left"'

run later '\EFI\Linux\boot-test_20261101.1+0-7.efi'
check "an entry that had no try left for long (+0-7) gets no drop-in" 'no_dropin later'

run plain '\EFI\Linux\boot-test_20261101.1.efi'
check "a name without a counter gets no drop-in" 'no_dropin plain && logged plain "names no counter"'

run garbage '\EFI\Linux\boot-test+x-1.efi'
check "a counter that is not a number gets no drop-in" 'no_dropin garbage'

run initrd '\EFI\Linux\boot-test_20261101.1+2-1.efi'
rm -rf "$WORK/initrd/out"
mkdir -p "$WORK/initrd/out"
: > "$WORK/initrd/etc/initrd-release"
GOLCONDA_TRIAL_BOOT_ROOT=$WORK/initrd sh "$GEN" "$WORK/initrd/out" "$WORK/initrd/early" "$WORK/initrd/late"
check "the initrd gets no drop-in" 'no_dropin initrd'

if [ "$ERRORS" -gt 0 ]; then
  echo "$ERRORS check(s) failed"
  exit 1
fi
echo "all checks passed"
