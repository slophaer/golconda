#!/bin/sh
# Unit test for scripts/golconda-etc-links. Builds a throwaway root with the
# link shapes PID 1 writes on first boot and checks what the generator rewrites.
set -eu

script="$1"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

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

if [ "$fail" != 0 ]; then
  exit 1
fi
echo "PASS: golconda-etc-links"
