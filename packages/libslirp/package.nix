# libslirp: QEMU's user-mode network (-netdev user: DHCP, hostfwd, guestfwd), for qemu-system.
# A development tool's library, not part of an image
{ package, pkgs }:
package {
  name = "libslirp";
  uses = [ "meson" ];
  dependencies = [ pkgs.glib ];
  platforms.os = [ "linux" ];
}
