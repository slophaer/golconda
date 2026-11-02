# The registry entries of modules/lib/fragment.nix: the module fragment and the types it is made of (file, units, links).
#
# An attribute set of registry entries, keyed by the type's base name; lib/schema.nix
# merges every lib/schema/registry-*.nix into `typeRegistry`. Every entry has a `description`.
{
  grammar,
  noControl,
  pattern,
  ...
}:
{
  # modules/lib/fragment.nix
  fragment = {
    description = "A module fragment with units, files, sysusers, tmpfiles, packages and links.";
    type = "object";
    additionalProperties = false;
    properties = {
      name = {
        type = "string";
      };
      units = {
        "$ref" = "#/$defs/units";
      };
      files = {
        type = "object";
        propertyNames = noControl // {
          type = "string";
          pattern = pattern "usrPath";
        };
        additionalProperties = {
          "$ref" = "#/$defs/file";
        };
        description = "Path -> file text or { text; mode; }, the same forms the composer accepts.";
      };
      sysusers = {
        type = "array";
        items = {
          type = "string";
        };
        description = "systemd-sysusers lines.";
      };
      tmpfiles = {
        type = "array";
        items = {
          type = "string";
        };
        description = "systemd-tmpfiles lines.";
      };
      packages = {
        type = "array";
        items = {
          type = "string";
          "x-golconda" = "package";
        };
        description = "Closure roots that go into /usr/nix/store; their bin lists become /usr/bin links.";
      };
      links = {
        "$ref" = "#/$defs/links";
      };
    };
  };

  file = {
    description = "File text (mode 0644), or { text; mode; }.";
    anyOf = [
      { type = "string"; }
      {
        type = "object";
        properties = {
          text = {
            type = "string";
          };
          mode = {
            type = "string";
            pattern = pattern "fileMode";
          };
        };
        required = [ "text" ];
        additionalProperties = false;
      }
    ];
  };

  fileMode = {
    description = "Four octal digits, like 0644 or 0755.";
    type = "string";
    pattern = pattern "fileMode";
  };

  unitName = {
    description = "A unit file name: a stem of letters, digits, : _ . @ - and one of .service .target .socket .timer .path .mount .slice.";
    type = "string";
    pattern = pattern "unitName";
  };

  unitText = {
    description = "Unit file text with at least one section header line, such as [Unit] or [Service].";
    type = "string";
    pattern = "(^|\n)${grammar.sectionHeader}(\n|$)";
  };

  units = {
    description = "Unit name -> unit file text, installed to `/usr/lib/systemd/system/<name>`; a user unit is a file under /usr/lib/systemd/user instead.";
    type = "object";
    propertyNames = {
      "$ref" = "#/$defs/unitName";
    };
    additionalProperties = {
      "$ref" = "#/$defs/unitText";
    };
  };

  links = {
    description = "Path under /usr -> link: the symlinks of the farm; the composer refuses a path with two sources, whatever their kinds.";
    type = "object";
    propertyNames = noControl // {
      type = "string";
      pattern = pattern "usrPath";
    };
    additionalProperties = {
      "$ref" = "#/$defs/link";
    };
  };

  link = {
    description = "A symlink in the /usr farm: { target; kind; }; its path is the key in `links`.";
    type = "object";
    properties = {
      target = noControl // {
        type = "string";
        minLength = 1;
        description = "Symlink target: a store path, or relative to the link (../sshd.service); for kind farm, a directory to link file by file.";
      };
      kind = {
        "$ref" = "#/$defs/linkKind";
      };
    };
    additionalProperties = false;
    required = [
      "target"
      "kind"
    ];
  };

  linkKind = {
    description = "What a link is for: package (`/usr/bin/<name>` from a bin list, derived by the composer), farm (a directory the image builder expands file by file), dlopen (a soname the builder checks resolves) or explicit (.wants and the like).";
    enum = [
      "package"
      "farm"
      "dlopen"
      "explicit"
    ];
  };
}
