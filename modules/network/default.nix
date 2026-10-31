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

  lines = l: concatStringsSep "\n" l + "\n";

  # Render an INI section from an attrset
  section =
    name: attrs:
    let
      render =
        k: v:
        if builtins.isList v then concatStringsSep "\n" (map (x: "${k}=${x}") v) else "${k}=${toString v}";
    in
    "[${name}]\n" + concatStringsSep "\n" (map (k: render k attrs.${k}) (attrNames attrs)) + "\n";

  # Network configuration: any attrset with at least a match field.
  # The structure check is done at render time, not at type check time,
  # because typedef' errors can be confusing with optionalAttr.
  networkConfig = types.attrs;

  # Render a .network file
  renderNetwork =
    _name: cfg:
    let
      matchSection = section "Match" cfg.match;
      networkSection = if cfg ? network then section "Network" cfg.network else "";
      linkSection = if cfg ? link then section "Link" cfg.link else "";
      dhcpV4Section = if cfg ? dhcpv4 then section "DHCPv4" cfg.dhcpv4 else "";
      addressSection = if cfg ? address then section "Address" cfg.address else "";
      routeSection = if cfg ? route then section "Route" cfg.route else "";
    in
    matchSection + networkSection + linkSection + dhcpV4Section + addressSection + routeSection;
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
      description = "Fallback DNS servers. Written to resolved.conf.d/golconda.conf.";
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
              text = lines [
                "[Resolve]"
                "DNS=${concatStringsSep " " options.dns}"
              ];
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
