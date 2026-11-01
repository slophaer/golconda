# Part of /base (modules/base/default.nix merges it): the D-Bus system bus on
# dbus-broker. The bus policy, the dbus.socket unit, the unit links, the links to
# systemd's bus files and the messagebus user. `p` is the package set. Returns { files; links; sysusers; }.
{ p }:
let
  inherit (import ../../lib/text.nix) lines;

  # D-Bus system bus configuration. dbus-broker reads /usr/share/dbus-1/system.conf but
  # does not ship it; this is the policy of the reference bus/system.conf.in (dbus 1.16):
  # every user may connect; no one owns a name or calls a method unless a policy file in
  # system.d allows it (systemd's, linked below, for network1, resolve1, login1, ...).
  # <user>, <listen> and <auth> are for dbus-daemon: dbus-broker takes its socket from
  # dbus.socket and ignores them.
  # <servicedir> is required: dbus-broker compiles in no default, so without it an
  # on-demand name (org.freedesktop.timedate1, for one) is "not activatable" and
  # timedatectl fails. The directory is the farm link to systemd's
  # share/dbus-1/system-services below; each file there names its unit
  # (SystemdService=), and systemd starts it on the first call.
  dbusSystemConf = ''
    <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
      "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
    <busconfig>
      <type>system</type>
      <user>messagebus</user>
      <auth>EXTERNAL</auth>
      <listen>unix:path=/run/dbus/system_bus_socket</listen>

      <policy context="default">
        <allow user="*"/>
        <deny own="*"/>
        <deny send_type="method_call"/>
        <allow send_type="signal"/>
        <allow send_requested_reply="true" send_type="method_return"/>
        <allow send_requested_reply="true" send_type="error"/>
        <allow receive_type="method_call"/>
        <allow receive_type="method_return"/>
        <allow receive_type="error"/>
        <allow receive_type="signal"/>
        <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus"/>
        <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Introspectable"/>
        <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Properties"/>
        <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Containers1"/>
        <deny send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus" send_member="UpdateActivationEnvironment"/>
        <deny send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Debug.Stats"/>
        <deny send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.systemd1.Activator"/>
      </policy>

      <policy user="root">
        <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.systemd1.Activator"/>
        <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Monitoring"/>
        <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Debug.Stats"/>
      </policy>

      <servicedir>/usr/share/dbus-1/system-services</servicedir>
      <includedir>system.d</includedir>
      <includedir>/etc/dbus-1/system.d</includedir>
      <include ignore_missing="yes">/etc/dbus-1/system-local.conf</include>
    </busconfig>
  '';

  # dbus.socket unit: dbus-broker needs the socket but doesn't ship it;
  # the socket activates dbus-broker.service (the dbus.service alias)
  dbusSocketUnit = lines [
    "# D-Bus system bus socket for dbus-broker"
    "[Unit]"
    "Description=D-Bus System Message Bus Socket"
    "Documentation=man:dbus-broker-launch(1)"
    "DefaultDependencies=no"
    "Before=sockets.target"
    ""
    "[Socket]"
    "ListenStream=/run/dbus/system_bus_socket"
    "SocketMode=0666"
    ""
    "[Install]"
    "WantedBy=sockets.target"
  ];

  # Explicit links for dbus-broker: the service from the package, and
  # the dbus.service alias pointing to dbus-broker.service.
  dbusUnitLinks = {
    "/usr/lib/systemd/system/dbus-broker.service" = {
      target = "${p.dbus-broker}/lib/systemd/system/dbus-broker.service";
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
  files = {
    # dbus.socket unit: dbus-broker doesn't ship it
    "/usr/lib/systemd/system/dbus.socket" = dbusSocketUnit;
    # D-Bus system bus configuration: dbus-broker does not ship it
    "/usr/share/dbus-1/system.conf" = dbusSystemConf;
  };

  links = dbusUnitLinks // dbusFarmLinks;

  # The dbus user, if dbus-broker needs it. dbus-broker runs as root by
  # default on most configurations (UID 0 in the unit), but the messagebus
  # user exists for compatibility.
  sysusers = [ "u messagebus - \"D-Bus message bus user\" -" ];
}
