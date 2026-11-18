#! Networkd configuration: one `.network` file for each entry of `networks`, and DHCP on every wired interface unless `defaultDhcp` is false.
#! An entry takes the table `match` and optional `network`, `link`, `dhcpv4`, `address` tables and `route`, a list of tables. Any other key is an error,
#! so a misspelt section cannot leave a machine without an address. The `dns` option sets the global fallback DNS servers.
#! A built-in component. A static network with two routes: docs/reference/config.md.
{ types, ... }:
let
  on = import ../lib/on.nix;
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
      # systemd reads one route from each [Route] section
      route = optionalAttr (listOf section);
    }).override
      { unknown = false; };

  # attrsOf checks values only; keys become direct .network filenames.
  # default-dhcp is the built-in network's name.
  networks = types.typedef' "networks" (
    v:
    let
      valuesError = (attrsOf network).verify v;
    in
    if valuesError != null then
      valuesError
    else if v ? default-dhcp then
      "'default-dhcp' is the name of the built-in DHCP network: give the network another name"
    else
      builtins.foldl' (
        err: name: if err != null then err else (import ../lib/path.nix).componentError name
      ) null (attrNames v)
  );

  # Render a .network file: the Match section plus each of the others that cfg has (cfg key ->
  # section name), then one [Route] section for each route. Sections come out in ini.nix's
  # order (sorted by name); systemd reads them in any order.
  sectionNames = {
    network = "Network";
    link = "Link";
    dhcpv4 = "DHCPv4";
    # the default network's only: the type of a network has no dhcpv6
    dhcpv6 = "DHCPv6";
    address = "Address";
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
    )
    + concatStringsSep "" (map (r: "\n" + ini.render { Route = r; }) (cfg.route or [ ]));
in
{
  name = "network";

  options = {
    networks = {
      type = networks;
      default = { };
      description = "Network configurations, keyed by name. Each becomes a .network file under /usr/lib/systemd/network/. The name default-dhcp is refused.";
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
          # the host name comes from /etc/hostname or the system.hostname credential, never from
          # a lease (docs/design/boot.md, "Bootstrap credentials")
          dhcpv4 = {
            UseDNS = "yes";
            UseHostname = "no";
            UseDomains = "yes";
          };
          dhcpv6.UseHostname = "no";
        };
      };

      # the type refuses a user network named default-dhcp
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

      dnsFile = on (options.dns != null) {
        "/usr/lib/systemd/resolved.conf.d/golconda-dns.conf" = {
          # FallbackDNS=, not DNS=: the option promises servers for the
          # case where no other DNS server is known, not global servers
          # that take part next to per-link ones.
          text = ini.render { Resolve.FallbackDNS = concatStringsSep " " options.dns; };
          mode = "0644";
        };
      };
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
