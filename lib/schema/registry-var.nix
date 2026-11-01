# The registry entries of modules/lib/var.nix: the var type.
#
# An attribute set of registry entries, keyed by the type's base name; lib/schema.nix
# merges every lib/schema/registry-*.nix into `typeRegistry`. Every entry has a `description`.
{ pattern, ... }:
{
  # modules/lib/var.nix
  var = {
    description = "A var: a value generated on the machine once, never in the image.";
    type = "object";
    properties = {
      name = {
        "$ref" = "#/$defs/word";
      };
      secrets = {
        type = "array";
        items = {
          "$ref" = "#/$defs/word";
        };
        description = "Files sealed as credentials `<name>.<file>`.";
      };
      publics = {
        type = "array";
        items = {
          "$ref" = "#/$defs/word";
        };
        description = "Files kept readable in `/var/lib/golconda/vars/<name>/pub/`.";
      };
      after = {
        type = "array";
        items = {
          "$ref" = "#/$defs/word";
        };
        description = "Vars that must run first.";
      };
      script = {
        type = "string";
        description = "POSIX sh script; runs in an empty runtime directory.";
      };
      packages = {
        type = "array";
        items = {
          type = "string";
          "x-golconda" = "package";
        };
        description = "Tools the script needs.";
      };
      wantedBy = {
        type = "array";
        items = {
          "$ref" = "#/$defs/targetName";
        };
        description = "Targets that pull in this unit.";
      };
    };
    required = [
      "name"
      "secrets"
      "script"
    ];
  };

  word = {
    description = "One path component: letters, digits, _ . -, not . or ...";
    type = "string";
    pattern = pattern "component";
  };
}
