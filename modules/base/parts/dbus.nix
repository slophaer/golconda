# Part of /base (modules/base/default.nix merges it): the D-Bus system bus on
# dbus-broker. The links to dbus-broker's units and bus policy (packages/dbus-broker
# installs system.conf and dbus.socket, which upstream does not ship), the links to
# systemd's bus files and the messagebus user. `p` is the package set. Returns
# { links; sysusers; }.
{ p }:
let
  # Explicit links for dbus-broker: the service and the socket from the package, the bus
  # policy dbus-broker-launch reads, and the dbus.service alias pointing to
  # dbus-broker.service.
  dbusUnitLinks = {
    "/usr/lib/systemd/system/dbus-broker.service" = {
      target = "${p.dbus-broker}/lib/systemd/system/dbus-broker.service";
      kind = "explicit";
    };
    "/usr/lib/systemd/system/dbus.socket" = {
      target = "${p.dbus-broker}/lib/systemd/system/dbus.socket";
      kind = "explicit";
    };
    "/usr/share/dbus-1/system.conf" = {
      target = "${p.dbus-broker}/share/dbus-1/system.conf";
      kind = "explicit";
    };
    # dbus.service alias points to dbus-broker.service
    "/usr/lib/systemd/system/dbus.service" = {
      target = "dbus-broker.service";
      kind = "explicit";
    };
    # static enablement: dbus.socket wanted by sockets.target
    "/usr/lib/systemd/system/sockets.target.wants/dbus.socket" = {
      target = "../dbus.socket";
      kind = "explicit";
    };
  };

  # Farm links (the image builder expands them file by file): systemd's bus policies
  # (system.conf includes system.d) and the activation files that map a bus name to its
  # unit (SystemdService=)
  dbusFarmLinks = {
    "/usr/share/dbus-1/system.d" = {
      target = "${p.systemd}/share/dbus-1/system.d";
      kind = "farm";
    };
    "/usr/share/dbus-1/system-services" = {
      target = "${p.systemd}/share/dbus-1/system-services";
      kind = "farm";
    };
  };
in
{
  links = dbusUnitLinks // dbusFarmLinks;

  # The dbus user, if dbus-broker needs it. dbus-broker runs as root by
  # default on most configurations (UID 0 in the unit), but the messagebus
  # user exists for compatibility.
  sysusers = [ "u messagebus - \"D-Bus message bus user\" -" ];
}
