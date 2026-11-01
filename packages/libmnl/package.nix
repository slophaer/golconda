# minimalistic netlink library, for iproute2
{ package }:
package {
  name = "libmnl";
  uses = [ "autotools" ];
  platforms.os = [ "linux" ];
}
