# The registry entries of modules/lib/service.nix: the service and its user, sandbox and ordering types.
#
# An attribute set of registry entries, keyed by the type's base name; lib/schema.nix
# merges every lib/schema/registry-*.nix into `typeRegistry`. Every entry has a `description`.
{ pattern, ... }:
{
  # modules/lib/service.nix
  service = {
    description = "A system service: an app plus what only a unit has (credentials, state, user, sandbox, ordering). Rendered as `ExecStart=/usr/bin/<program> <argv>` with the app's files under `/usr/lib/<name>/`.";
    type = "object";
    properties = {
      name = {
        "$ref" = "#/$defs/serviceName";
      };
      app = {
        "$ref" = "#/$defs/app";
      };
      credentials = {
        type = "object";
        additionalProperties = {
          "$ref" = "#/$defs/credentialId";
        };
        description = "Credential name -> credstore id (one name, never a path).";
      };
      credentialFallbacks = {
        type = "object";
        additionalProperties = {
          type = "string";
          minLength = 1;
        };
        description = "Credential name (declared in credentials) -> public text PID 1 gives the service when the sealed credential is missing (SetCredential=). In the unit file: never a secret.";
      };
      state = {
        type = "array";
        items = {
          "$ref" = "#/$defs/stateDirectory";
        };
        description = "StateDirectory entries under /var/lib, one directory name each.";
      };
      runtimeDirectory = {
        "$ref" = "#/$defs/word";
        description = "RuntimeDirectory= under /run.";
      };
      killMode = {
        "$ref" = "#/$defs/killMode";
      };
      user = {
        "$ref" = "#/$defs/serviceUser";
      };
      sandbox = {
        "$ref" = "#/$defs/sandbox";
      };
      after = {
        type = "array";
        items = {
          "$ref" = "#/$defs/unitName";
        };
        description = "Units to order after.";
      };
      wants = {
        type = "array";
        items = {
          "$ref" = "#/$defs/unitName";
        };
        description = "Units to want.";
      };
      wantedBy = {
        type = "array";
        items = {
          "$ref" = "#/$defs/targetName";
        };
        description = "Targets that pull in this unit.";
      };
    };
    additionalProperties = false;
    required = [
      "name"
      "app"
      "user"
      "sandbox"
    ];
  };

  credentialId = {
    description = "A systemd credential id: letters, digits and _ . : @ -, one name in the credstore, never a path.";
    type = "string";
    pattern = pattern "credentialId";
  };

  stateDirectory = {
    description = "A StateDirectory= entry: one directory name under /var/lib (letters, digits, _ . -), not . or ...";
    type = "string";
    pattern = pattern "component";
  };

  serviceName = {
    description = "Valid systemd unit name stem.";
    type = "string";
    pattern = pattern "serviceName";
  };

  serviceUser = {
    description = "Who runs the service (User=): root.";
    enum = [ "root" ];
  };

  sandbox = {
    description = "Sandbox profile: strict (most restricted), default, or trusted (least restricted).";
    enum = [
      "strict"
      "default"
      "trusted"
    ];
  };

  killMode = {
    description = "KillMode=: control-group (default), process (children outlive the daemon, as sshd's sessions) or mixed.";
    enum = [
      "control-group"
      "process"
      "mixed"
    ];
  };

  targetName = {
    description = "A systemd target name (must end with .target).";
    type = "string";
    pattern = pattern "targetName";
  };
}
