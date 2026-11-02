# The registry entries of the types that modules/<dir>/default.nix declares for itself
# (factory, system, network, pkgs). The types shared between modules mirror
# modules/lib/<file>.nix, one registry file each.
#
# An attribute set of registry entries, keyed by the type's base name; lib/schema.nix
# merges every lib/schema/registry-*.nix into `typeRegistry`. Every entry has a `description`.
{ pattern, ... }:
{
  # modules/factory
  etcFiles = {
    description = "Path under /etc -> file: factory files seeded with tmpfiles L lines. Machine-owned names and generated static links are reserved.";
    type = "object";
    propertyNames = {
      type = "string";
      pattern = pattern "etcPath";
      not.enum = [
        "passwd"
        "group"
        "shadow"
        "gshadow"
        "machine-id"
        "hostname"
        "localtime"
        "os-release"
      ];
    };
    additionalProperties = {
      "$ref" = "#/$defs/file";
    };
  };
  timezone = {
    description = "An IANA zone name, such as UTC or Europe/Berlin: /etc/localtime links to /usr/share/zoneinfo/<timezone>.";
    type = "string";
    pattern = pattern "timezone";
  };

  # modules/system/default.nix: the image id and version, one grammar each
  imageName = {
    description = "Image id: letters, digits and _ . -, starting with a letter or digit.";
    type = "string";
    pattern = pattern "imageName";
  };

  version = {
    description = "Image version: YYYYMMDD.N, such as 20261031.1; N has no leading zero.";
    type = "string";
    pattern = pattern "version";
  };

  # modules/network/default.nix
  networks = {
    description = "Network configurations keyed by one filename component.";
    type = "object";
    propertyNames = {
      type = "string";
      pattern = pattern "component";
    };
    additionalProperties = {
      "$ref" = "#/$defs/network";
    };
  };

  network = {
    description = "A .network file: `match` (the Match section) and the optional sections network, link, dhcpv4, address and route. Any other key is an error.";
    type = "object";
    properties = {
      match = {
        "$ref" = "#/$defs/networkSection";
      };
      network = {
        "$ref" = "#/$defs/networkSection";
      };
      link = {
        "$ref" = "#/$defs/networkSection";
      };
      dhcpv4 = {
        "$ref" = "#/$defs/networkSection";
      };
      address = {
        "$ref" = "#/$defs/networkSection";
      };
      route = {
        "$ref" = "#/$defs/networkSection";
      };
    };
    required = [ "match" ];
    additionalProperties = false;
  };

  networkSection = {
    description = "One section of a .network file: key -> value. A list repeats the key, a boolean is yes or no, null leaves the key out.";
    type = "object";
    additionalProperties = {
      anyOf = [
        { type = "string"; }
        { type = "integer"; }
        { type = "boolean"; }
        { type = "null"; }
        {
          type = "array";
          items = {
            type = [
              "string"
              "integer"
              "boolean"
            ];
          };
        }
      ];
    };
  };

  # modules/pkgs/default.nix
  repkgsSet = {
    description = "The repkgs set of one platform (nix/packages.nix): `pkgs` and the rest. nix/default.nix passes it as options.\"/pkgs\".target and options.\"/pkgs\".build; a configuration document cannot.";
    "x-golconda" = "set";
  };
}
