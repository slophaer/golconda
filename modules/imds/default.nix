#! Cloud instance metadata (IMDS) through systemd-imds, with systemd's own import.
#!
#! An optional component with no options: a configuration includes it with
#! an empty table, `["/imds"]`. Without the table, `/base` keeps every IMDS
#! unit off. With it, systemd's IMDS stack runs where
#! `systemd-imds-generator` finds a cloud by hwdb (Hetzner, AWS, GCP, Azure
#! and others, `40-imds.hwdb`): `systemd-imdsd` behind
#! `/run/systemd/io.systemd.InstanceMetadata`, the early network file and its
#! prohibit route (systemd is built `imds-network=locked`: only imdsd reaches
#! the endpoint, and it answers root only, as systemd has no polkit here),
#! and `systemd-imds-import.service`, once the network is online and before
#! `sysinit.target`. On other machines no import runs.
#!
#! What the import delivers, as systemd writes it:
#! - the host name, as the credential `firstboot.hostname`:
#!   `systemd-firstboot` writes it to `/etc/hostname` on the first boot, so
#!   it wins over a `system.hostname` credential from then on;
#! - the first ssh key, as `ssh.authorized_keys.root`: `systemd-tmpfiles`
#!   writes `/root/.ssh/authorized_keys` from it when the file does not exist,
#!   and sshd reads that file. Not on Hetzner: it lists the keys only as a
#!   JSON array, which systemd-imds cannot read; give the key in the user
#!   data as the credential `ssh.authorized_keys.root`;
#! - the public IPv4 and IPv6 addresses, as resolved's local records for
#!   `_public`;
#! - every credential the user data lists under `systemd.credentials`, in
#!   `/run/credstore` (or `/run/credstore.encrypted`); a unit that imports a
#!   credential of that name gets it. The user data is measured into PCR 12.
#!
#! The metadata endpoint is plain HTTP without authentication: whoever can
#! answer on its address (169.254.169.254 on most clouds) sets the host
#! name, root's ssh key and any credential, such as `tmpfiles.extra`. Opt in
#! only where the network to the endpoint is trusted, as it is when the
#! hypervisor serves it. Put no secret in user data: every root process on
#! the machine can read it.
#!
#! Configuration, no program of its own: the `.wants` link that hangs the
#! import on the early network unit (the cmdline's `systemd.imds.import=0`
#! keeps the generator from pulling it into the initrd, which has no
#! network), a drop-in that orders the import before
#! `systemd-tmpfiles-setup.service` (the reader of `ssh.authorized_keys.root`
#! and `tmpfiles.*`), drop-ins that keep DHCP leases from setting the host
#! name in every `.network` file of `/network` and in the early network file,
#! and the unit below. Hetzner Cloud's endpoint paths come from systemd's
#! hwdb: systemd 262's `40-imds.hwdb` asks Hetzner for
#! `/hetzner/v1/metadata/public-keys/0` and `/hetzner/v1/metadata/userdata`,
#! which answer 404, and `packages/systemd` patches it to the base URL
#! `http://169.254.169.254/hetzner/v1`, the keys under `/metadata/`, the
#! user data at `/userdata`, and no ssh key.
#!
#! A user data credential `network.network.*` (also `.netdev`, `.link`) takes
#! effect in the boot that imports it, such as Hetzner's static IPv6 address
#! (`Address=<prefix>::1/64`, `Gateway=fe80::1`; Hetzner sends no router
#! advertisement for it). systemd-network-generator reads these credentials
#! before networkd starts, long before the import. So
#! `golconda-imds-network.service`, pulled in by the import and ordered after
#! it, runs systemd's `systemd-network-generator` again with them and then
#! `networkctl reload`. Such a file replaces `85-imds-early.network` for the
#! links it matches, and with it the prohibit route and the fwmark rule of
#! `imds-network=locked`. So `/imds` keeps the lock on `lo` as well
#! (`10-golconda-imds-lock.network`): policy rules that send imdsd's packets
#! to imdsd's table, then to the main table, and refuse every other packet
#! to 169.254.169.254. Set `UseHostname=no` in such a file.
_:
let
  ini = import ../lib/ini.nix;
  inherit (import ../lib/text.nix) lines;
  netDir = "/usr/lib/systemd/network";
  importUnit = "systemd-imds-import.service";

  # The user data's network.* credentials (a static IPv6 address: Hetzner sends no router
  # advertisement for it, and has no DHCPv6) reach /run/credstore only with the import, after
  # network-online.target; systemd-network-generator.service, their reader, ran before networkd.
  # So it runs a second time after the import, with the same credentials, and networkd reloads:
  # the generator writes /run/systemd/network/<name>.network, and the reload configures each link
  # whose file changed. systemd's own programs, no script. Pulled in by the import, so it runs
  # only where the import runs.
  # The IMDS lock, on lo. systemd-imdsd's 85-imds-early.network holds it: a prohibit route to the
  # endpoint, a route to it in table 0x7FFF0815, and a rule that sends imdsd's packets (firewall
  # mark 0x7FFF0815) to that table. networkd gives a link one .network file, so a user data file
  # for the link (golconda-imds-network.service) replaces the early file, and the lock goes with
  # it. Policy rules belong to no link, so these are on lo, which no such file matches, and they
  # come before the rule imdsd's file adds (networkd gives a rule without Priority= the highest
  # free one, 32765): imdsd's packets look in imdsd's table first, then in the main table (the
  # early file's prohibit route is there only while its table has the route); every other packet
  # to the endpoint is refused. 169.254.169.254 is the endpoint of every IPv4 entry in
  # 40-imds.hwdb.
  lockFile = lines [
    "# Generated by Golconda (/imds): only systemd-imdsd reaches the IMDS endpoint,"
    "# whatever .network file a link has"
    "[Match]"
    "Name=lo"
    ""
    "[RoutingPolicyRule]"
    "FirewallMark=0x7FFF0815"
    "Table=0x7FFF0815"
    "Priority=32100"
    ""
    "[RoutingPolicyRule]"
    "FirewallMark=0x7FFF0815"
    "Table=main"
    "Priority=32101"
    ""
    "[RoutingPolicyRule]"
    "To=169.254.169.254/32"
    "Type=prohibit"
    "Priority=32102"
  ];

  netUnit = "golconda-imds-network.service";
  netUnitText = lines [
    "# Generated by Golconda (/imds), docs/features/provisioning.md"
    "[Unit]"
    "Description=Network Units from IMDS User Data Credentials"
    "Documentation=man:systemd-network-generator.service(8)"
    "DefaultDependencies=no"
    "After=${importUnit}"
    "Before=sysinit.target shutdown.target"
    "Conflicts=shutdown.target"
    ""
    "[Service]"
    "Type=oneshot"
    "RemainAfterExit=yes"
    "ImportCredential=network.netdev.*"
    "ImportCredential=network.link.*"
    "ImportCredential=network.network.*"
    "ExecStart=/usr/lib/systemd/systemd-network-generator"
    "ExecStart=/usr/bin/networkctl reload"
  ];
in
{
  name = "imds";

  # /network's .network files: each gets a drop-in, as the host name comes from IMDS
  inputs.network.path = "/network";

  impl =
    { results }:
    let
      # networkd reads <name>.network.d/ in every network directory, so a drop-in in /usr also
      # reaches /run/systemd/network/85-imds-early.network, which systemd-imdsd writes on a cloud
      # (DHCP with UseHostname=yes)
      networkFiles = builtins.filter (p: builtins.match "${netDir}/[^/]+[.]network" p != null) (
        builtins.attrNames results.network.files
      );
      dhcpNames = map baseNameOf networkFiles ++ [ "85-imds-early.network" ];
      # networkd would set the host name from a lease, before the import and at each renewal
      noDhcpHostname = ini.render {
        DHCPv4.UseHostname = false;
        DHCPv6.UseHostname = false;
      };
      file = text: {
        inherit text;
        mode = "0644";
      };
    in
    {
      files = {
        "${netDir}/10-golconda-imds-lock.network" = file lockFile;
        # /base's drop-ins turn the IMDS units on by this path (modules/base/parts/imds.nix)
        "/usr/lib/golconda/imds" = file ''
          # Generated by Golconda (/imds): systemd's IMDS units run on a cloud that hwdb names.
          # modules/base/parts/imds.nix conditions them on this file.
        '';
        # the import writes /run/credstore/ssh.authorized_keys.root (and the user data's
        # tmpfiles.*, login.*): systemd-tmpfiles-setup.service reads them when it starts
        "/usr/lib/systemd/system/${importUnit}.d/golconda-imds.conf" = file ''
          # Generated by Golconda (/imds)
          [Unit]
          Before=systemd-tmpfiles-setup.service
        '';
      }
      // builtins.listToAttrs (
        map (n: {
          name = "${netDir}/${n}.d/golconda-imds.conf";
          value = file ("# Generated by Golconda (/imds): the host name comes from IMDS\n" + noDhcpHostname);
        }) dhcpNames
      );
      units.${netUnit} = netUnitText;
      # The generator pulls the early network unit on a cloud only, and it pulls the import, which
      # pulls the second network generator run.
      # Not the socket: systemd's preset (no `disable *`) enables it on every machine.
      links = {
        "/usr/lib/systemd/system/systemd-imds-early-network.service.wants/${importUnit}" = {
          target = "../${importUnit}";
          kind = "explicit";
        };
        "/usr/lib/systemd/system/${importUnit}.wants/${netUnit}" = {
          target = "../${netUnit}";
          kind = "explicit";
        };
      };
    };
}
