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
  typeRegistry = {
    # modules/lib/fragment.nix
    fragment = {
      type = "object";
      description = "A module fragment with units, files, sysusers, tmpfiles, packages.";
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
        };
        tmpfiles = {
          type = "array";
          items = {
            type = "string";
          };
        };
        packages = {
          type = "array";
          items = {
            type = "string";
            "x-golconda" = "package";
          };
        };
      };
    };

    file = {
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
      description = "File text, or { text; mode; }.";
    };

    fileMode = {
      type = "string";
      pattern = "^[0-7]{4}$";
      description = "Four octal digits, like 0644 or 0755.";
    };

    # modules/lib/app.nix
    argv = {
      type = "array";
      items = {
        type = "string";
      };
      description = "Program arguments (strings only in app.argv; credential refs only in service.extraArgv).";
    };

    appFiles = {
      type = "object";
      additionalProperties = {
        type = "string";
      };
      description = "File name -> text, no per-machine values.";
    };

    envOp = {
      type = "object";
      description = "Environment operation: one of set, default, prepend, append, unset.";
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
      description = "{ credential; prefix?; } rendered as <prefix>%d/credential.";
    };

    credentialPrefix = {
      type = "string";
      pattern = "^[A-Za-z0-9_=:/.,+-]*$";
    };

    # modules/lib/service.nix
    serviceName = {
      type = "string";
      pattern = "^[A-Za-z0-9:_.\\-]+$";
      description = "Valid systemd unit name stem.";
    };

    serviceUser = {
      type = "string";
      description = "\"dynamic\", \"root\", or a sysusers line.";
    };

    sandbox = {
      enum = [
        "strict"
        "default"
        "trusted"
      ];
      description = "Sandbox profile: strict, default, or trusted.";
    };

    # modules/lib/var.nix
    word = {
      type = "string";
      pattern = "^[A-Za-z0-9_.-]+$";
      description = "One path component: letters, digits, _ . -";
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
