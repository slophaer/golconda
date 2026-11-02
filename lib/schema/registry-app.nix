# The registry entries of modules/lib/app.nix: the app and its argv, files, environment and credential references.
#
# An attribute set of registry entries, keyed by the type's base name; lib/schema.nix
# merges every lib/schema/registry-*.nix into `typeRegistry`. Every entry has a `description`.
{ noControl, pattern, ... }:
{
  # modules/lib/app.nix
  app = {
    description = "What a program needs to run, with nothing systemd-specific.";
    type = "object";
    properties = {
      package = {
        type = "string";
        "x-golconda" = "package";
        description = "The package; its first bin entry is the program.";
      };
      program = {
        "$ref" = "#/$defs/programName";
      };
      argv = {
        "$ref" = "#/$defs/argv";
      };
      env = {
        "$ref" = "#/$defs/env";
      };
      files = {
        "$ref" = "#/$defs/appFiles";
      };
    };
    required = [ "package" ];
    additionalProperties = false;
  };

  argv = {
    description = "Program arguments after the executable: strings (no control character) and credential references, which render as `<prefix>%d/<credential>`.";
    type = "array";
    items = {
      anyOf = [
        (noControl // { type = "string"; })
        { "$ref" = "#/$defs/credentialRef"; }
      ];
    };
  };

  appFiles = {
    description = "File name -> text, installed to `/usr/lib/<service>/<name>`; the name is relative (it cannot leave that directory), and a file holds no per-machine value.";
    type = "object";
    propertyNames = noControl // {
      type = "string";
      pattern = pattern "relativePath";
    };
    additionalProperties = {
      type = "string";
    };
  };

  envOp = {
    description = "Environment operation: set the value, or unset the variable (true only).";
    type = "object";
    oneOf = [
      {
        properties.set = {
          "$ref" = "#/$defs/unitValue";
        };
        required = [ "set" ];
        additionalProperties = false;
      }
      {
        properties.unset = {
          const = true;
        };
        required = [ "unset" ];
        additionalProperties = false;
      }
    ];
  };

  env = {
    description = "Environment variable name -> operation; the name is letters, digits and _, and does not start with a digit.";
    type = "object";
    propertyNames = {
      type = "string";
      pattern = pattern "envName";
    };
    additionalProperties = {
      "$ref" = "#/$defs/envOp";
    };
  };

  unitValue = {
    description = "A value on one line of a unit: a string with no control character (a newline would add a directive).";
    type = "string";
  }
  // noControl;

  programName = {
    description = "An executable name in /usr/bin: letters, digits and _ @ . + -, never a path.";
    type = "string";
    pattern = pattern "programName";
  };

  credentialRef = {
    description = "{ credential; prefix?; } in an argv, rendered as `<prefix>%d/<credential>`; the service must declare the credential.";
    type = "object";
    properties = {
      credential = {
        type = "string";
      };
      prefix = {
        type = "string";
      };
    };
    required = [ "credential" ];
    additionalProperties = false;
  };

  credentialPrefix = {
    description = "A credential argument prefix: letters, digits, and _ = : / . , + -.";
    type = "string";
    pattern = pattern "credentialPrefix";
  };
}
