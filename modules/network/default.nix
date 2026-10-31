#! Networkd configuration.
#!
#! Default: DHCP on all wired (ethernet) interfaces. No configuration
#! needed for a typical server or VM.
#!
#! Options: `networks` is a map from network name to network config. Each
#! config has `match` (Match section) and `network` (Network section) keys.
#! Example: `{ networks.static = { match.Name = "eth0"; network.Address = "10.0.0.1/24"; }; }`
#!
#! The `dns` option sets the global fallback DNS servers (used when no
#! interface-specific DNS is configured).
{ types, ... }:
let
  inherit (builtins) concatStringsSep mapAttrs attrNames;
  inherit (types)
    listOf
    option
    string
    ;

  ini = import ../lib/ini.nix;

  # Network configuration: any attrset with at least a match field.
  # The structure check is done at render time, not at type check time,
  # because typedef' errors can be confusing with optionalAttr.
  networkConfig = types.attrs;

  # Render a .network file: the Match section plus each of the others that cfg has (cfg key ->
  # section name). Sections come out in ini.nix's order (sorted by name); systemd reads them in
  # any order.
  sectionNames = {
    network = "Network";
    link = "Link";
    dhcpv4 = "DHCPv4";
    address = "Address";
    route = "Route";
  };
  renderNetwork =
    _name: cfg:
    ini.render (
      {
        Match = cfg.match;
      }
      // builtins.listToAttrs (
        map (k: {
          name = sectionNames.${k};
          value = cfg.${k};
        }) (builtins.filter (k: cfg ? ${k}) (attrNames sectionNames))
      )
    );
in
{
  name = "network";

  options = {
    networks = {
      type = types.optionalAttr networkConfig;
      default = { };
      description = "Network configurations, keyed by name. Each becomes a .network file under /usr/lib/systemd/network/.";
    };
    dns = {
      type = option (listOf string);
      default = null;
      description = "Fallback DNS servers. Written to resolved.conf.d/golconda-dns.conf.";
    };
    defaultDhcp = {
      type = types.bool;
      default = true;
      description = "When true (default), enable DHCP on all wired interfaces (Type=ether). Set to false to use only explicit networks.";
    };
  };

  impl =
    { options, ... }:
    let
      # Default DHCP network for all wired interfaces (Type=ether excludes loopback)
      defaultNetwork = {
        default-dhcp = {
          match.Type = "ether";
          network = {
            DHCP = "yes";
            IPv6AcceptRA = "yes";
          };
          dhcpv4 = {
            UseDNS = "yes";
            UseHostname = "yes";
            UseDomains = "yes";
          };
        };
      };

      # Merge default with user networks (user wins on conflict)
      allNetworks = if options.defaultDhcp then defaultNetwork // options.networks else options.networks;

      # Generate network files
      networkFiles = mapAttrs (name: cfg: {
        path = "/usr/lib/systemd/network/${name}.network";
        text = renderNetwork name cfg;
      }) allNetworks;

      # DNS fallback configuration
      dnsFile =
        if options.dns != null then
          {
            "/usr/lib/systemd/resolved.conf.d/golconda-dns.conf" = {
              text = ini.render { Resolve.DNS = concatStringsSep " " options.dns; };
              mode = "0644";
            };
          }
        else
          { };
    in
    {
      files =
        builtins.listToAttrs (
          map (name: {
            name = networkFiles.${name}.path;
            value = {
              text = networkFiles.${name}.text;
              mode = "0644";
            };
          }) (attrNames networkFiles)
        )
        // dnsFile;
    };
}
