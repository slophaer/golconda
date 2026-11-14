#!/bin/sh
# golconda-update-pending (modules/system) without a machine: a stub bootctl on PATH prints a
# `bootctl list` of each case. The update is pending only when systemd-boot's default entry is not
# the running one (docs/design/updates.md, "Activation").
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
PENDING=$ROOT/modules/system/golconda-update-pending
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ERRORS=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/bootctl" <<'EOF'
#!/bin/sh
[ "$1" = list ] || exit 2
[ -f "$BOOTCTL_LIST" ] || exit 1
cat "$BOOTCTL_LIST"
EOF
chmod +x "$WORK/bin/bootctl"
export PATH="$WORK/bin:$PATH"

# entry ID TITLE-SUFFIX TRIES: one entry of `bootctl list` as systemd 262 prints it without a tty
entry() {
  printf '         type: Boot Loader Specification Type #2 (.efi)\n'
  printf '        title: Golconda %s%s\n' "$1" "$2"
  printf '           id: boot-test_%s.efi\n' "$1"
  [ -z "$3" ] || printf '        tries: %s\n' "$3"
  printf '\n'
}

# expect NAME STATUS: the program exits with STATUS for $BOOTCTL_LIST
expect() {
  st=0
  sh "$PENDING" > "$WORK/out" 2>&1 || st=$?
  if [ "$st" = "$2" ]; then pass "$1"; else fail "$1 (exit $st: $(cat "$WORK/out"))"; fi
}

export BOOTCTL_LIST="$WORK/list"
{ entry 20261031.2 ' (default)' '3 left; 0 done'; entry 20261031.1 ' (selected)' ''; } > "$BOOTCTL_LIST"
expect "a new release installed: pending" 0

{ entry 20261031.2 ' (default) (selected)' ''; entry 20261031.1 '' ''; } > "$BOOTCTL_LIST"
expect "the new release runs, blessed: nothing pending" 1

{ entry 20261031.1 ' (default) (selected)' ''; entry 20261031.2 '' '0 left; 3 done'; } > "$BOOTCTL_LIST"
expect "after a fallback, the failed release still installed: nothing pending" 1

{ entry 20261031.2 ' (default) (selected)' '2 left; 1 done'; entry 20261031.1 '' ''; } > "$BOOTCTL_LIST"
expect "a trial boot of the new release: nothing pending" 1

{ entry 20261031.1 ' (default)' ''; entry 20261031.2 ' (selected)' '0 left; 4 done'; } > "$BOOTCTL_LIST"
expect "the failed release started by hand, with no try left: pending (sysupdate's own check decides)" 0

{ entry 20261031.2 ' (default)' ''; entry 20261031.1 '' ''; } > "$BOOTCTL_LIST"
expect "no entry selected (not started by systemd-boot): nothing pending" 1

rm -f "$BOOTCTL_LIST"
expect "bootctl fails: nothing pending" 1

if [ "$ERRORS" -gt 0 ]; then
  echo "$ERRORS check(s) failed"
  exit 1
fi
echo "all checks passed"
