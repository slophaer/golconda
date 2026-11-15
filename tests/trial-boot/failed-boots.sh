#!/bin/sh
# The failed-boot counter (modules/base/golconda-failed-boots) without a machine:
# GOLCONDA_FAILED_BOOTS_ROOT points it at a scratch tree with a fake efivarfs, /proc/sys, /run and
# /dev/kmsg; stub chattr, bootctl and systemctl on PATH record what it asks for. With the defaults
# (3 and 6): the third boot in a row that does not complete sets a one-shot boot of the other slot
# and records its own entry, the seventh reboots on no failure, and a complete boot resets the count
# and, on the other slot, renames the recorded entry's UKI on the fake ESP to +0-3
# (docs/design/boot.md, "Failed boots").
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ERRORS=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# the program as /base renders it with the default thresholds
PROG=$WORK/golconda-failed-boots
while IFS= read -r line; do
  case $line in
    'fallback=@fallback@') echo 'fallback=3' ;;
    'halt=@halt@') echo 'halt=6' ;;
    *) printf '%s\n' "$line" ;;
  esac
done < "$ROOT/modules/base/golconda-failed-boots" > "$PROG"

LOADER=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
EFI=sys/firmware/efi/efivars
COUNT=$EFI/GolcondaFailedBoots-d1b3416f-c0f9-44e8-8b5a-cbb64676bdef
ONESHOT=$EFI/LoaderEntryOneShot-$LOADER
FAILED=$EFI/GolcondaFailedEntry-d1b3416f-c0f9-44e8-8b5a-cbb64676bdef
LINUX=boot/EFI/Linux

# utf16 STRING...: an EFI variable's bytes for a list of strings: 4 bytes of attributes, then each
# string in UTF-16LE with its NUL (LoaderEntries is such a list, LoaderEntrySelected a list of one).
# A file of its own: the stub bootctl uses it too
cat > "$WORK/utf16.sh" <<'EOF'
utf16() {
  printf '\007\000\000\000'
  for s in "$@"; do
    while [ -n "$s" ]; do
      c=${s%"${s#?}"}
      s=${s#?}
      printf '%s\000' "$c"
    done
    printf '\000\000'
  done
}
EOF
# shellcheck source=/dev/null # written above
. "$WORK/utf16.sh"

mkdir -p "$WORK/bin"
# the stubs log their arguments to $r/calls; bootctl writes the one-shot variable as systemd's does
cat > "$WORK/bin/chattr" <<'EOF'
#!/bin/sh
echo "chattr $*" >> "$GOLCONDA_FAILED_BOOTS_ROOT/calls"
EOF
cat > "$WORK/bin/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$GOLCONDA_FAILED_BOOTS_ROOT/calls"
case $1 in is-active) exit "${BOOT_COMPLETE_INACTIVE:-0}" ;; esac
EOF
cat > "$WORK/bin/bootctl" <<EOF
#!/bin/sh
echo "bootctl \$*" >> "\$GOLCONDA_FAILED_BOOTS_ROOT/calls"
. "$WORK/utf16.sh"
[ "\$1" != --print-esp-path ] || { echo "\$GOLCONDA_FAILED_BOOTS_ROOT/boot"; exit 0; }
[ "\$1" = set-oneshot ] || exit 2
if [ -z "\$2" ]; then rm -f "\$GOLCONDA_FAILED_BOOTS_ROOT/$ONESHOT"; else utf16 "\$2" > "\$GOLCONDA_FAILED_BOOTS_ROOT/$ONESHOT"; fi
EOF
chmod +x "$WORK/bin/chattr" "$WORK/bin/systemctl" "$WORK/bin/bootctl"
export PATH="$WORK/bin:$PATH"

# boot CASE SELECTED COUNT [ENTRIES...]: a fresh root that booted SELECTED, with COUNT in the
# counter variable (none when empty) and LoaderEntries ENTRIES (default: both slots and an auto
# entry)
boot() {
  r=$WORK/$1
  sel=$2
  n=$3
  shift 3
  [ $# -gt 0 ] || set -- boot-test_20261031.2.efi boot-test_20261031.1.efi auto-reboot-to-firmware-setup
  mkdir -p "$r/$EFI" "$r/dev" "$r/proc/sys/kernel" "$r/run" "$r/etc" "$r/$LINUX"
  : > "$r/dev/kmsg"
  : > "$r/calls"
  echo 10 > "$r/proc/sys/kernel/panic"
  utf16 "$sel" > "$r/$EFI/LoaderEntrySelected-$LOADER"
  utf16 "$@" > "$r/$EFI/LoaderEntries-$LOADER"
  [ -z "$n" ] || printf '\007\000\000\000%s' "$n" > "$r/$COUNT"
}
run() { GOLCONDA_FAILED_BOOTS_ROOT=$WORK/$1 sh "$PROG" "$2"; }
count_is() { [ "$(tail -c +5 "$WORK/$1/$COUNT")" = "$2" ] && [ "$(head -c 4 "$WORK/$1/$COUNT" | od -An -tx1 | tr -d ' ')" = 07000000 ]; }
logged() { grep -qF "$2" "$WORK/$1/dev/kmsg"; }
called() { grep -qxF "$2" "$WORK/$1/calls"; }
oneshot_is() { [ "$(tail -c +5 "$WORK/$1/$ONESHOT" | tr -d '\000')" = "$2" ]; }
no_halt() {
  [ "$(cat "$WORK/$1/proc/sys/kernel/panic")" = 10 ] && [ ! -e "$WORK/$1/run/golconda/failed-boots-halt" ] &&
    [ ! -e "$WORK/$1/run/systemd/system.conf.d" ] && ! called "$1" "systemctl daemon-reload"
}

boot first boot-test_20261031.2.efi ""
run first count
check "a first boot writes 1 and does nothing else" \
  'count_is first 1 && [ ! -s "$WORK/first/dev/kmsg" ] && [ ! -e "$WORK/first/$ONESHOT" ] && no_halt first'

boot garbage boot-test_20261031.2.efi x7
run garbage count
check "a count that is not a number counts as 0" 'count_is garbage 1'

boot second boot-test_20261031.2.efi 1
run second count
check "the second boot in a row logs one failed boot and sets no one-shot" \
  'count_is second 2 && logged second "golconda-failed-boots: failed boots in a row: 1" && [ ! -e "$WORK/second/$ONESHOT" ] && no_halt second'

boot third boot-test_20261031.2.efi 2
run third count
check "the third boot in a row sets a one-shot boot of the other slot" \
  'count_is third 3 && called third "bootctl set-oneshot boot-test_20261031.1.efi" && oneshot_is third boot-test_20261031.1.efi &&
   logged third "golconda-failed-boots: the next boot starts boot-test_20261031.1.efi once" &&
   [ "$(cat "$WORK/third/run/golconda/failed-boots-oneshot")" = boot-test_20261031.1.efi ] && no_halt third &&
   [ "$(tail -c +5 "$WORK/third/$FAILED")" = boot-test_20261031.2.efi ]'

boot fallback boot-test_20261031.1.efi 3
run fallback count
check "the fourth boot (the other slot) sets no one-shot again" \
  'count_is fallback 4 && ! called fallback "bootctl set-oneshot boot-test_20261031.2.efi" && no_halt fallback'

boot alone boot-test_20261031.2.efi 2 boot-test_20261031.2.efi auto-efi-shell
run alone count
check "with no other slot there is no one-shot" \
  'count_is alone 3 && [ ! -e "$WORK/alone/$ONESHOT" ] && logged alone "no other entry"'

boot sixth boot-test_20261031.2.efi 5
run sixth count
check "the sixth boot in a row still reboots on a failure" 'count_is sixth 6 && no_halt sixth'

boot halt boot-test_20261031.2.efi 6
run halt count
check "the seventh boot in a row stops rebooting: kernel.panic=0, CrashAction=freeze, no watchdog, no trial reboot" \
  'count_is halt 7 && [ "$(cat "$WORK/halt/proc/sys/kernel/panic")" = 0 ] &&
   grep -qx "CrashAction=freeze" "$WORK/halt/run/systemd/system.conf.d/golconda-crash.conf" &&
   grep -qx "RuntimeWatchdogSec=off" "$WORK/halt/run/systemd/system.conf.d/golconda-watchdog.conf" &&
   [ -f "$WORK/halt/run/systemd/system/initrd.target.d/golconda-trial-boot.conf" ] &&
   ! grep -q JobTimeoutAction "$WORK/halt/run/systemd/system/initrd.target.d/golconda-trial-boot.conf" &&
   [ -e "$WORK/halt/run/golconda/failed-boots-halt" ] && called halt "systemctl daemon-reload" &&
   logged halt "golconda-failed-boots: failed boots in a row: 6: this boot reboots on no failure (kernel.panic=0, CrashAction=freeze, no watchdog)" &&
   [ ! -e "$WORK/halt/$ONESHOT" ]'

# complete: a blessed boot (no LoaderBootCountPath) completes at multi-user.target
boot blessed boot-test_20261031.1.efi 4
mkdir -p "$WORK/blessed/run/golconda"
echo boot-test_20261031.2.efi > "$WORK/blessed/run/golconda/failed-boots-oneshot"
utf16 boot-test_20261031.2.efi > "$WORK/blessed/$ONESHOT"
run blessed complete
check "a complete boot removes the count and the one-shot it set" \
  'called blessed "chattr -i $WORK/blessed/$COUNT" && [ ! -e "$WORK/blessed/$COUNT" ] && [ ! -e "$WORK/blessed/$ONESHOT" ] &&
   logged blessed "golconda-failed-boots: this boot completed after 3 failed boots: the count is reset"'

boot quiet boot-test_20261031.1.efi 1
run quiet complete
check "a complete boot after none that failed logs nothing" '[ ! -e "$WORK/quiet/$COUNT" ] && [ ! -s "$WORK/quiet/dev/kmsg" ]'

boot operator boot-test_20261031.1.efi 2
mkdir -p "$WORK/operator/run/golconda"
echo boot-test_20261031.2.efi > "$WORK/operator/run/golconda/failed-boots-oneshot"
utf16 boot-test_20261031.1.efi > "$WORK/operator/$ONESHOT"
run operator complete
check "a one-shot the counter did not set stays" '[ ! -e "$WORK/operator/$COUNT" ] && oneshot_is operator boot-test_20261031.1.efi'

# complete on the other slot: the entry that failed is marked bad as systemd-boot marks one
boot marked boot-test_20261031.1.efi 4
printf '\007\000\000\000%s' boot-test_20261031.2.efi > "$WORK/marked/$FAILED"
: > "$WORK/marked/$LINUX/boot-test_20261031.2.efi"
: > "$WORK/marked/$LINUX/boot-test_20261031.1.efi"
run marked complete
check "the other slot completed: the failed entry's UKI becomes +0-3, the record goes" \
  '[ -e "$WORK/marked/$LINUX/boot-test_20261031.2+0-3.efi" ] && [ ! -e "$WORK/marked/$LINUX/boot-test_20261031.2.efi" ] &&
   [ -e "$WORK/marked/$LINUX/boot-test_20261031.1.efi" ] && [ ! -e "$WORK/marked/$FAILED" ] && [ ! -e "$WORK/marked/$COUNT" ] &&
   logged marked "golconda-failed-boots: boot-test_20261031.2.efi failed 3 boots in a row: marked bad, boot-test_20261031.2+0-3.efi"'

boot counted-bad boot-test_20261031.1.efi 4
printf '\007\000\000\000%s' boot-test_20261031.2.efi > "$WORK/counted-bad/$FAILED"
: > "$WORK/counted-bad/$LINUX/boot-test_20261031.2+1-2.efi"
run counted-bad complete
check "a failed entry with a counter loses its tries too" \
  '[ -e "$WORK/counted-bad/$LINUX/boot-test_20261031.2+0-3.efi" ] && [ ! -e "$WORK/counted-bad/$LINUX/boot-test_20261031.2+1-2.efi" ]'

boot exhausted boot-test_20261031.1.efi 4
printf '\007\000\000\000%s' boot-test_20261031.2.efi > "$WORK/exhausted/$FAILED"
: > "$WORK/exhausted/$LINUX/boot-test_20261031.2+0-4.efi"
run exhausted complete
check "an entry with no try left keeps its name" \
  '[ -e "$WORK/exhausted/$LINUX/boot-test_20261031.2+0-4.efi" ] && [ ! -e "$WORK/exhausted/$FAILED" ]'

boot recovered boot-test_20261031.2.efi 3
printf '\007\000\000\000%s' boot-test_20261031.2.efi > "$WORK/recovered/$FAILED"
: > "$WORK/recovered/$LINUX/boot-test_20261031.2.efi"
run recovered complete
check "the failed entry itself completed: nothing is marked bad" \
  '[ -e "$WORK/recovered/$LINUX/boot-test_20261031.2.efi" ] && [ ! -e "$WORK/recovered/$FAILED" ] && [ ! -e "$WORK/recovered/$COUNT" ]'

boot counted boot-test_20261031.2.efi 2
utf16 '\EFI\Linux\boot-test_20261031.2+2-1.efi' > "$WORK/counted/$EFI/LoaderBootCountPath-$LOADER"
BOOT_COMPLETE_INACTIVE=3 run counted complete
check "a counted boot whose boot-complete.target failed keeps the count" \
  'count_is counted 2 && logged counted "boot-complete.target was not reached"'

boot blessed-now boot-test_20261031.2.efi 2
utf16 '\EFI\Linux\boot-test_20261031.2+2-1.efi' > "$WORK/blessed-now/$EFI/LoaderBootCountPath-$LOADER"
run blessed-now complete
check "a counted boot that reached boot-complete.target resets the count" \
  '[ ! -e "$WORK/blessed-now/$COUNT" ] && called blessed-now "systemctl is-active --quiet boot-complete.target"'

boot none boot-test_20261031.2.efi ""
run none complete
check "complete without a count does nothing" '[ ! -s "$WORK/none/calls" ]'

if [ "$ERRORS" -gt 0 ]; then
  echo "$ERRORS check(s) failed"
  exit 1
fi
echo "all checks passed"
