#!/bin/sh
# Unit test for modules/base/golconda-etc-links. Builds a throwaway root with the
# link shapes PID 1 writes on first boot and checks what the generator rewrites.
set -eu

script="$1"
root="$(mktemp -d)"
trap 'chmod -R u+w "$root"; rm -rf "$root"' EXIT

new_store="$root/usr/nix/store/11111111111111111111111111111111-systemd/lib/systemd/system"
old_store="/usr/nix/store/22222222222222222222222222222222-systemd/lib/systemd/system"
mkdir -p "$new_store" \
  "$root/usr/lib/systemd/system/multi-user.target.wants" \
  "$root/etc/systemd/system/multi-user.target.wants" \
  "$root/etc/systemd/system/sockets.target.wants"

for unit in getty@.service dbus.socket; do
  : > "$new_store/$unit"
  ln -s "../../../nix/store/11111111111111111111111111111111-systemd/lib/systemd/system/$unit" \
    "$root/usr/lib/systemd/system/$unit"
done

# a first-boot link from an older systemd store path
ln -s "$old_store/getty@.service" \
  "$root/etc/systemd/system/multi-user.target.wants/getty@tty1.service"
# a top-level alias whose target name is a file in /usr/lib/systemd/system
ln -s "$old_store/dbus.socket" "$root/etc/systemd/system/dbus.socket"
# a mask and a link into /etc must stay untouched
ln -s /dev/null "$root/etc/systemd/system/console-getty.service"
ln -s /etc/systemd/system/dbus.socket "$root/etc/systemd/system/dbus-alias.socket"
# a store link whose unit is not in /usr/lib/systemd/system must stay untouched
ln -s "$old_store/gone.service" "$root/etc/systemd/system/gone.service"
# a relative link inside /etc must stay untouched
ln -s ../dbus.socket "$root/etc/systemd/system/sockets.target.wants/dbus.socket"

GOLCONDA_ROOT="$root" sh "$script"

fail=0
check() {
  want="$1"
  path="$2"
  got="$(readlink "$root/$path")"
  if [ "$got" != "$want" ]; then
    echo "FAIL: $path -> $got (want $want)" >&2
    fail=1
  fi
}

check "/usr/lib/systemd/system/getty@.service" \
  "etc/systemd/system/multi-user.target.wants/getty@tty1.service"
check "/usr/lib/systemd/system/dbus.socket" "etc/systemd/system/dbus.socket"
check "/dev/null" "etc/systemd/system/console-getty.service"
check "/etc/systemd/system/dbus.socket" "etc/systemd/system/dbus-alias.socket"
check "$old_store/gone.service" "etc/systemd/system/gone.service"
check "../dbus.socket" "etc/systemd/system/sockets.target.wants/dbus.socket"

# A rewrite that fails must fail the unit and name the link. A read-only
# directory stands in for a root mounted read-only: every ln in it fails.
wants="$root/etc/systemd/system/multi-user.target.wants"
rm -f "$wants/getty@tty1.service"
ln -s "$old_store/getty@.service" "$wants/getty@tty1.service"
# a link visited after the failure, in a writable directory
ln -s "$old_store/getty@.service" "$root/etc/systemd/system/sockets.target.wants/getty@tty2.service"
chmod a-w "$wants"
if touch "$wants/.probe" 2>/dev/null; then
  # root ignores the mode: nothing here can make ln fail, so say so
  rm -f "$wants/.probe"
  echo "SKIP: read-only case (root can write a read-only directory)"
else
  status=0
  GOLCONDA_ROOT="$root" sh "$script" > "$root/out" 2> "$root/err" || status=$?
  if [ "$status" = 0 ]; then
    echo "FAIL: a failed rewrite exited 0" >&2
    fail=1
  fi
  if ! grep -q "multi-user.target.wants/getty@tty1.service" "$root/err"; then
    echo "FAIL: the error does not name the link; stderr was:" >&2
    cat "$root/err" >&2
    fail=1
  fi
  # the link is unchanged, and the script went on to the next link
  check "$old_store/getty@.service" "etc/systemd/system/multi-user.target.wants/getty@tty1.service"
  check "/usr/lib/systemd/system/getty@.service" "etc/systemd/system/sockets.target.wants/getty@tty2.service"
fi
chmod u+w "$wants"

if [ "$fail" != 0 ]; then
  exit 1
fi
echo "PASS: golconda-etc-links"
