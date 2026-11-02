#! Networkd configuration.
#!
#! Default: DHCP on all wired (ethernet) interfaces. No configuration
#! needed for a typical server or VM.
#!
#! Options: `networks` is a map from network name to network config. Each
#! config has a `match` table (the Match section) and may have `network`,
#! `link`, `dhcpv4`, `address` and `route` tables, one for each section of
#! the same name. Any other key is an error, so a misspelt section cannot
#! leave a machine without an address.
#! Example: `{ networks.static = { match.Name = "eth0"; network.Address = "10.0.0.1/24"; }; }`
#!
#! The `dns` option sets the global fallback DNS servers (used when no
#! interface-specific DNS is configured).
{ types, ... }:
let
  inherit (builtins) concatStringsSep mapAttrs attrNames;
  inherit (types)
    attrsOf
    bool
    int
    listOf
    option
    optionalAttr
    string
    struct
    union
    ;

  ini = import ../lib/ini.nix;

  # One section of a .network file: key -> value. ini.nix renders a list as a
  # repeated key, a boolean as yes/no and null as no line, and it refuses a key
  # or a value that would change the file's structure.
  iniScalar = union [
    string
    int
    bool
  ];
  section = attrsOf (union [
    iniScalar
    (listOf iniScalar)
    types.null
  ]);

  # A network: `match` is required, the other sections are optional, and any
  # other key is refused. systemd spells the sections with capitals
  # ([Network]), so `Network` is the likely typo; it must fail here, at
  # evaluation, not render to a file with [Match] only.
  network =
    (struct "network" {
      match = section;
      network = optionalAttr section;
      link = optionalAttr section;
      dhcpv4 = optionalAttr section;
      address = optionalAttr section;
      route = optionalAttr section;
    }).override
      { unknown = false; };

  # attrsOf checks values only; keys become direct .network filenames.
  networks = types.typedef' "networks" (
    v:
    let
      valuesError = (attrsOf network).verify v;
    in
    if valuesError != null then
      valuesError
    else
      builtins.foldl' (
        err: name: if err != null then err else (import ../lib/path.nix).componentError name
      ) null (attrNames v)
  );

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
      type = networks;
      default = { };
      description = "Network configurations, keyed by name. Each becomes a .network file under /usr/lib/systemd/network/.";
    };
    dns = {
      type = option (listOf string);
      default = null;
      description = "Fallback DNS servers. Written to resolved.conf.d/golconda-dns.conf.";
    };
    defaultDhcp = {
      type = bool;
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

      # Generate network files. networkd tries the files that match an
      # interface in lexical order and the first match wins, so an explicit
      # network must sort before the catch-all DHCP file. Prefixes make that
      # order independent of the names the operator chose.
      networkPrefix = name: if name == "default-dhcp" then "99-" else "50-";
      networkFiles = mapAttrs (name: cfg: {
        path = "/usr/lib/systemd/network/${networkPrefix name}${name}.network";
        text = renderNetwork name cfg;
      }) allNetworks;

      # DNS fallback configuration
      dnsFile =
        if options.dns != null then
          {
            "/usr/lib/systemd/resolved.conf.d/golconda-dns.conf" = {
              # FallbackDNS=, not DNS=: the option promises servers for the
              # case where no other DNS server is known, not global servers
              # that take part next to per-link ones.
              text = ini.render { Resolve.FallbackDNS = concatStringsSep " " options.dns; };
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
