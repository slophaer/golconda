# JSON Schema 2020-12 export from the adios module tree.
#
# `toJsonSchema tree` walks the loaded tree and emits one JSON Schema object
# with `properties.<modulePath>` per module. Options become properties with
# their description, default/example when they are plain data, and a type
# derived from the korora type name.
#
# Korora does not expose `members` on struct types or `elems` on enum types.
# A local registry lets Golconda's own types register their schema explicitly.
# Mark the gap with `x-golconda-opaque` for types that cannot be introspected.
#
# Usage:
#   let schema = import ./lib/schema.nix { };
#   in schema.toJsonSchema tree
_:
let
  inherit (builtins)
    attrNames
    filter
    foldl'
    head
    isAttrs
    isBool
    isFloat
    isInt
    isList
    isString
    length
    listToAttrs
    mapAttrs
    match
    stringLength
    substring
    tail
    ;

  # Parse a generic type name like "listOf<string>" or "attrsOf<listOf<int>>"
  # Returns { base; args; } where base is the type constructor and args is the
  # list of type arguments (as strings).
  parseTypeName =
    name:
    let
      m = match "([a-zA-Z]+)<(.*)>" name;
    in
    if m == null then
      {
        base = name;
        args = [ ];
      }
    else
      {
        base = head m;
        args = parseTypeArgs (head (tail m));
      };

  # Parse comma-separated type arguments, handling nested generics.
  # "string,int" -> [ "string" "int" ]
  # "listOf<string>,int" -> [ "listOf<string>" "int" ]
  parseTypeArgs =
    s:
    let
      len = stringLength s;
      # Walk the string, tracking angle-bracket depth
      go =
        i: depth: start: acc:
        if i >= len then
          acc ++ [ (substring start (i - start) s) ]
        else
          let
            c = substring i 1 s;
          in
          if c == "<" then
            go (i + 1) (depth + 1) start acc
          else if c == ">" then
            go (i + 1) (depth - 1) start acc
          else if c == "," && depth == 0 then
            go (i + 1) 0 (i + 1) (acc ++ [ (substring start (i - start) s) ])
          else
            go (i + 1) depth start acc;
    in
    go 0 0 0 [ ];

  # Registry of Golconda's custom types with their JSON Schema. Each entry is
  # keyed by the type's base name (__name) and maps to a JSON Schema fragment.
  # Types that are opaque or whose schema depends on their usage are not here;
  # they get x-golconda-opaque in the output.
  #
  # Every entry MUST have a `description` field; the test enforces this.
  typeRegistry = {
    # modules/lib/fragment.nix
    fragment = {
      description = "A module fragment with units, files, sysusers, tmpfiles, packages, links, farm, and dlopen.";
      type = "object";
      properties = {
        units = {
          type = "object";
          additionalProperties = {
            type = "string";
          };
          description = "Unit name -> unit file text.";
        };
        files = {
          type = "object";
          additionalProperties = {
            type = "object";
            properties = {
              text = {
                type = "string";
              };
              mode = {
                type = "string";
                pattern = "^[0-7]{4}$";
              };
            };
            required = [ "text" ];
          };
          description = "Path -> file with text and mode.";
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
          description = "Closure roots that go into /usr/nix/store and /usr/bin.";
        };
        links = {
          type = "array";
          items = {
            "$ref" = "#/$defs/link";
          };
          description = "Symlinks in the /usr farm.";
        };
        farm = {
          type = "object";
          additionalProperties = {
            type = "array";
            items = {
              type = "string";
            };
          };
          description = "Package name -> subdirs to link file by file into /usr.";
        };
        dlopen = {
          type = "object";
          additionalProperties = {
            type = "array";
            items = {
              type = "string";
            };
          };
          description = "Package name -> sonames to link into /usr/lib for dlopen.";
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
              pattern = "^[0-7]{4}$";
            };
          };
          required = [ "text" ];
        }
      ];
    };

    fileMode = {
      description = "Four octal digits, like 0644 or 0755.";
      type = "string";
      pattern = "^[0-7]{4}$";
    };

    link = {
      description = "A symlink: { path; target; }.";
      type = "object";
      properties = {
        path = {
          type = "string";
          description = "Absolute path under /usr.";
        };
        target = {
          type = "string";
          description = "Symlink target (absolute or relative).";
        };
      };
      required = [
        "path"
        "target"
      ];
    };

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
        argv = {
          "$ref" = "#/$defs/argv";
        };
        env = {
          type = "object";
          additionalProperties = {
            "$ref" = "#/$defs/envOp";
          };
          description = "Environment operations.";
        };
        files = {
          "$ref" = "#/$defs/appFiles";
        };
      };
      required = [ "package" ];
    };

    argv = {
      description = "Program arguments (strings only in app.argv; credential refs only in service.extraArgv).";
      type = "array";
      items = {
        type = "string";
      };
    };

    appFiles = {
      description = "File name -> text, no per-machine values.";
      type = "object";
      additionalProperties = {
        type = "string";
      };
    };

    envOp = {
      description = "Environment operation: one of set, default, prepend, append, unset.";
      type = "object";
      oneOf = [
        {
          properties.set = {
            type = "string";
          };
          required = [ "set" ];
        }
        {
          properties.default = {
            type = "string";
          };
          required = [ "default" ];
        }
        {
          properties.prepend = {
            type = "array";
            items.type = "string";
          };
          required = [ "prepend" ];
        }
        {
          properties.append = {
            type = "array";
            items.type = "string";
          };
          required = [ "append" ];
        }
        {
          properties.unset = {
            type = "boolean";
          };
          required = [ "unset" ];
        }
      ];
    };

    credentialRef = {
      description = "{ credential; prefix?; } rendered as `<prefix>%d/<credential>`.";
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
    };

    credentialPrefix = {
      description = "A credential argument prefix: letters, digits, and _ = : / . , + -.";
      type = "string";
      pattern = "^[A-Za-z0-9_=:/.,+-]*$";
    };

    # modules/lib/service.nix
    service = {
      description = "A service: an app plus what only a unit has (credentials, state, user, sandbox, ordering).";
      type = "object";
      properties = {
        name = {
          "$ref" = "#/$defs/serviceName";
        };
        app = {
          "$ref" = "#/$defs/app";
        };
        extraArgv = {
          type = "array";
          items = {
            anyOf = [
              { type = "string"; }
              { "$ref" = "#/$defs/credentialRef"; }
            ];
          };
          description = "Unit-only arguments after app.argv.";
        };
        credentials = {
          type = "object";
          additionalProperties = {
            type = "string";
          };
          description = "Credential name -> credstore id.";
        };
        state = {
          type = "array";
          items = {
            type = "string";
          };
          description = "StateDirectory entries under /var/lib.";
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
            type = "string";
          };
          description = "Units to order after.";
        };
        wants = {
          type = "array";
          items = {
            type = "string";
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
      required = [
        "name"
        "app"
        "user"
        "sandbox"
      ];
    };

    serviceName = {
      description = "Valid systemd unit name stem.";
      type = "string";
      pattern = "^[A-Za-z0-9:_.\\-]+$";
    };

    serviceUser = {
      description = "\"dynamic\", \"root\", or a sysusers line.";
      type = "string";
    };

    sandbox = {
      description = "Sandbox profile: strict (most restricted), default, or trusted (least restricted).";
      enum = [
        "strict"
        "default"
        "trusted"
      ];
    };

    targetName = {
      description = "A systemd target name (must end with .target).";
      type = "string";
      pattern = "^[A-Za-z0-9:_.\\-]+\\.target$";
    };

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
          description = "Files sealed as credentials <name>.<file>.";
        };
        publics = {
          type = "array";
          items = {
            "$ref" = "#/$defs/word";
          };
          description = "Files kept readable in /var/lib/golconda/vars/<name>/pub/.";
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
      description = "One path component: letters, digits, _ . -.";
      type = "string";
      pattern = "^[A-Za-z0-9_.-]+$";
    };
  };

  # Check if a value is plain data (serialisable to JSON).
  isPlainData =
    v:
    if isString v || isBool v || isInt v || isFloat v || v == null then
      true
    else if isList v then
      builtins.all isPlainData v
    else if isAttrs v then
      !(v ? outPath || v ? __functor) && builtins.all isPlainData (builtins.attrValues v)
    else
      false;

  # Primitive type name to JSON Schema mapping.
  primitiveSchema = {
    string = {
      type = "string";
    };
    str = {
      type = "string";
    };
    int = {
      type = "integer";
    };
    bool = {
      type = "boolean";
    };
    float = {
      type = "number";
    };
    number = {
      type = "number";
    };
    null = {
      type = "null";
    };
    any = { }; # any type
    derivation = {
      type = "string";
      "x-golconda" = "package";
    };
    path = {
      type = "string";
      "x-golconda" = "path";
    };
    pathLike = {
      type = "string";
      "x-golconda" = "path";
    };
    function = {
      "x-golconda-opaque" = "function";
    };
  };

  # Polymorphic type to JSON Schema (needs parsed type arguments).
  polymorphicSchema =
    baseName: parsed:
    if baseName == "listOf" && parsed.args != [ ] then
      {
        type = "array";
        items = typeToSchemaByName (head parsed.args);
      }
    else if baseName == "attrsOf" && parsed.args != [ ] then
      {
        type = "object";
        additionalProperties = typeToSchemaByName (head parsed.args);
      }
    else if (baseName == "option" || baseName == "optionalAttr") && parsed.args != [ ] then
      typeToSchemaByName (head parsed.args)
    else if baseName == "union" && parsed.args != [ ] then
      { anyOf = map typeToSchemaByName parsed.args; }
    else if baseName == "tuple" && parsed.args != [ ] then
      {
        type = "array";
        items = false;
        prefixItems = map typeToSchemaByName parsed.args;
        minItems = length parsed.args;
        maxItems = length parsed.args;
      }
    # Struct/enum without exposed members/elems: mark as opaque
    else
      null;

  # Convert a korora type to a JSON Schema fragment.
  typeToSchema =
    t:
    let
      name = t.name or "";
      baseName = t.__name or (parseTypeName name).base;
      parsed = parseTypeName name;
      poly = polymorphicSchema baseName parsed;
    in
    typeRegistry.${baseName} or primitiveSchema.${baseName}
      or (if poly != null then poly else { "x-golconda-opaque" = baseName; });

  # Convert a type name string to JSON Schema (for parsed generic arguments).
  typeToSchemaByName =
    name:
    let
      parsed = parseTypeName name;
      baseName = parsed.base;
      poly = polymorphicSchema baseName parsed;
    in
    typeRegistry.${baseName} or primitiveSchema.${baseName}
      or (if poly != null then poly else { "x-golconda-opaque" = baseName; });

  # Remove null values from an attrset.
  filterNulls =
    attrs:
    listToAttrs (
      filter (x: x.value != null) (
        map (n: {
          name = n;
          value = attrs.${n};
        }) (attrNames attrs)
      )
    );

  # Convert one adios option to a JSON Schema property.
  optionToSchema =
    opt:
    filterNulls (
      (typeToSchema opt.type)
      // {
        description = opt.description or null;
        default = if opt ? default && isPlainData opt.default then opt.default else null;
        examples = if opt ? example && isPlainData opt.example then [ opt.example ] else null;
      }
    );

  # Walk one module, returning { properties; } for its options.
  moduleToSchema =
    mod:
    let
      opts = mod.options or { };
      props = mapAttrs (_: optionToSchema) opts;
    in
    filterNulls {
      type = "object";
      description = mod.name or null;
      properties = if props == { } then null else props;
    };

  # Walk the module tree recursively, building the properties object.
  # Path is the current module path (list of strings).
  walkModules =
    path: mods:
    foldl' (
      acc: name:
      let
        mod = mods.${name};
        fullPath = path ++ [ name ];
        pathStr = "/" + builtins.concatStringsSep "/" fullPath;
        # This module's schema (if it has options)
        thisSchema =
          if mod ? options && mod.options != { } then { ${pathStr} = moduleToSchema mod; } else { };
        # Recurse into submodules
        subSchemas = if mod ? modules && mod.modules != { } then walkModules fullPath mod.modules else { };
      in
      acc // thisSchema // subSchemas
    ) { } (attrNames mods);

  # The main export function.
  toJsonSchema =
    tree:
    let
      allModules = walkModules [ ] tree.modules;
    in
    {
      "$schema" = "https://json-schema.org/draft/2020-12/schema";
      "$id" = "https://golconda.dev/schema.json";
      title = "Golconda configuration";
      description = "Configuration options for Golconda modules.";
      type = "object";
      properties = allModules;
    };
in
{
  inherit
    toJsonSchema
    typeToSchema
    typeToSchemaByName
    optionToSchema
    moduleToSchema
    typeRegistry
    parseTypeName
    parseTypeArgs
    isPlainData
    ;
}
