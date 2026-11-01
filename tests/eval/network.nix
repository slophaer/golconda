# Checks of /network: networkd configuration, rendered through modules/lib/ini.nix, and INI scalars.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  composeWith,
  configLib,
  f,
  hasInfix,
  schemaLib,
  ...
}:
let
  inherit (builtins)
    attrNames
    deepSeq
    elem
    filter
    sort
    split
    tryEval
    ;
in
[
  (check "ini: lists repeat the key, booleans are yes/no, null drops" (
    (import ../../modules/lib/ini.nix).render {
      A = {
        k = [
          "x"
          "y"
        ];
        b = true;
        n = null;
      };
    } == "[A]\nb=yes\nk=x\nk=y\n"
  ))
  # 12. /network: networkd configuration
  (check "network: default DHCP on all wired interfaces" (
    let
      result = composeWith {
        "/network" = { };
      };
    in
    result.files ? "/usr/lib/systemd/network/99-default-dhcp.network"
    && hasInfix "[Match]" result.files."/usr/lib/systemd/network/99-default-dhcp.network".text
    && hasInfix "Type=ether" result.files."/usr/lib/systemd/network/99-default-dhcp.network".text
    && hasInfix "DHCP=yes" result.files."/usr/lib/systemd/network/99-default-dhcp.network".text
  ))
  (check "network: defaultDhcp=false disables default network" (
    let
      result = composeWith {
        "/network".defaultDhcp = false;
      };
    in
    !(result.files ? "/usr/lib/systemd/network/99-default-dhcp.network")
  ))
  (check "network: dns option configures resolved" (
    let
      result = composeWith {
        "/network".dns = [
          "1.1.1.1"
          "8.8.8.8"
        ];
      };
    in
    result.files ? "/usr/lib/systemd/resolved.conf.d/golconda-dns.conf"
    # the whole line: "FallbackDNS=..." must not pass a "DNS=" assertion
    && elem "FallbackDNS=1.1.1.1 8.8.8.8" (
      split "\n" result.files."/usr/lib/systemd/resolved.conf.d/golconda-dns.conf".text
    )
  ))
  (check "network: custom network config" (
    let
      result = composeWith {
        "/network" = {
          defaultDhcp = false;
          networks.static = {
            match.Name = "eth0";
            network.Address = "10.0.0.1/24";
          };
        };
      };
    in
    result.files ? "/usr/lib/systemd/network/50-static.network"
    && hasInfix "Name=eth0" result.files."/usr/lib/systemd/network/50-static.network".text
    && hasInfix "Address=10.0.0.1/24" result.files."/usr/lib/systemd/network/50-static.network".text
    && !(result.files ? "/usr/lib/systemd/network/99-default-dhcp.network")
  ))
  (check "network: an explicit network sorts before the default DHCP file" (
    let
      result = composeWith {
        "/network" = {
          networks.static = {
            match.Name = "eth0";
            network.Address = "10.0.0.1/24";
          };
        };
      };
      files = attrNames result.files;
      names = filter (p: hasInfix "/systemd/network/" p) files;
      sorted = sort (a: b: a < b) names;
    in
    # networkd takes the first matching file: static must come first
    names == [
      "/usr/lib/systemd/network/50-static.network"
      "/usr/lib/systemd/network/99-default-dhcp.network"
    ]
    && sorted == names
  ))
  # /network renders through modules/lib/ini.nix
  (check "network: files are ini.nix output (sections sorted, lists repeat, booleans yes/no)" (
    let
      result = composeWith {
        "/network" = {
          defaultDhcp = false;
          dns = [
            "1.1.1.1"
            "8.8.8.8"
          ];
          networks.static = {
            match.Name = "eth0";
            network = {
              Address = [
                "10.0.0.1/24"
                "10.0.1.1/24"
              ];
              IPv6AcceptRA = false;
            };
            route.Gateway = "10.0.0.254";
          };
        };
      };
    in
    result.files."/usr/lib/systemd/network/50-static.network".text
    == "[Match]\nName=eth0\n\n[Network]\nAddress=10.0.0.1/24\nAddress=10.0.1.1/24\nIPv6AcceptRA=no\n\n[Route]\nGateway=10.0.0.254\n"
    &&
      result.files."/usr/lib/systemd/resolved.conf.d/golconda-dns.conf".text
      == "[Resolve]\nFallbackDNS=1.1.1.1 8.8.8.8\n"
  ))
  (check "network: a section the config lacks is not rendered" (
    let
      result = composeWith {
        "/network" = {
          defaultDhcp = false;
          networks.bare.match.Name = "lo";
        };
      };
    in
    result.files."/usr/lib/systemd/network/50-bare.network".text == "[Match]\nName=lo\n"
  ))
  # A network is a closed struct: a misspelt section is an error at evaluation,
  # never a file with [Match] only (the machine would get no address and no DHCP).
  (check "network: an unknown section key is refused, and the message names it" (
    let
      networksType = (f.modules { }).modules.network.options.networks.type;
      lan = section: {
        lan = {
          match.Name = "eth0";
          ${section}.Address = "10.0.0.5/24";
        };
      };
      err = networksType.verify (lan "Network");
      rendered =
        net:
        (tryEval (
          deepSeq
            (composeWith {
              "/network".networks = net;
            }).files
            true
        )).success;
    in
    err != null
    && hasInfix "'Network'" err
    && networksType.verify (lan "network") == null
    && !(rendered (lan "Network"))
    && rendered (lan "network")
    # match is required, and the message says so
    && hasInfix "'match'" (networksType.verify { lan.network.DHCP = "yes"; })
    # a section is a table of keys, not a string
    &&
      networksType.verify {
        lan = {
          match.Name = "eth0";
          network = "DHCP=yes";
        };
      } != null
  ))
  (check "network: the TOML route refuses the misspelt section and renders the right one" (
    let
      load =
        section:
        (configLib.loadConfigText ''
          ["/network".networks.lan]
          match = { Name = "eth0" }
          ${section} = { Address = "10.0.0.5/24" }
        '').options;
      files = section: (composeWith (load section)).files;
      good = files "network";
    in
    !(tryEval (deepSeq (files "Network") true)).success
    &&
      good."/usr/lib/systemd/network/50-lan.network".text
      == "[Match]\nName=eth0\n\n[Network]\nAddress=10.0.0.5/24\n"
  ))
  (check "schema: a network is a closed object with match required" (
    let
      net =
        (schemaLib.toJsonSchema (f.modules { }))
        .properties."/network".properties.networks.additionalProperties;
    in
    net.additionalProperties == false
    && net.required == [ "match" ]
    &&
      attrNames net.properties == [
        "address"
        "dhcpv4"
        "link"
        "match"
        "network"
        "route"
      ]
  ))
  # An INI scalar cannot change the file's structure
  (check "ini: a line break in a value, a key or a section is refused" (
    let
      ini = import ../../modules/lib/ini.nix;
      iniThrows = sections: !(tryEval (deepSeq (ini.render sections) true)).success;
    in
    iniThrows {
      Source = {
        Path = "https://x/\n[Evil]";
      };
    }
    && iniThrows {
      Source = {
        "Path\nType" = "x";
      };
    }
    && iniThrows {
      "Source]\n[Evil" = {
        Path = "x";
      };
    }
    && iniThrows {
      Source = {
        MatchPattern = [ "a\nb" ];
      };
    }
    # positive: the shapes the image renders pass, lists included
    && !(iniThrows {
      Source = {
        Type = "url-file";
        Path = "https://example.com/";
        MatchPattern = [
          "a_@v.raw"
          "b_@v.raw"
        ];
      };
    })
  ))
]
