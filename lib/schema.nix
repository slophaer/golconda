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
# Provenance: every option carries `x-golconda-declaredIn` ({ module;
# file?; line? }: the module path that declares it, that module's file relative to
# the repo, and the line of the option in it, when the evaluator reports a position: iets does, nix does not), and every module `x-golconda-inputs`,
# the module paths it reads (its `inputs.<x>.path`, sorted): the edges of the module
# graph. `toJsonSchemaWith { files; root; }` knows the files: `files` maps a module
# path to its file path (module-docs.nix `discoverModulePaths`, as a list of
# { path; filePath; }), `root` is the repo directory as a string; the files and lines
# are left out without them.
#
# Usage:
#   let schema = import ./lib/schema.nix { };
#   in schema.toJsonSchema tree
_:
let
  inherit (builtins)
    attrNames
    attrValues
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
    sort
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
      description = "A module fragment with units, files, sysusers, tmpfiles, packages and links.";
      type = "object";
      properties = {
        units = {
          "$ref" = "#/$defs/units";
        };
        files = {
          type = "object";
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

    # modules/system/default.nix: the image id and version, one grammar each
    imageName = {
      description = "Image id: letters, digits and _ . -, starting with a letter or digit.";
      type = "string";
      pattern = "^[A-Za-z0-9][A-Za-z0-9._-]*$";
    };

    version = {
      description = "Image version: YYYYMMDD.N, such as 20261031.1; N has no leading zero.";
      type = "string";
      pattern = "^[0-9]{8}\\.(0|[1-9][0-9]*)$";
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

    unitName = {
      description = "A unit file name: a stem of letters, digits, : _ . @ - and one of .service .target .socket .timer .path .mount .slice.";
      type = "string";
      pattern = "^[A-Za-z0-9:_.@\\-]+\\.(service|target|socket|timer|path|mount|slice)$";
    };

    unitText = {
      description = "Unit file text with at least one section header line, such as [Unit] or [Service].";
      type = "string";
      pattern = "(^|\n)\\[[A-Za-z]+\\](\n|$)";
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
      propertyNames = {
        type = "string";
        pattern = "^/usr/.+";
      };
      additionalProperties = {
        "$ref" = "#/$defs/link";
      };
    };

    link = {
      description = "A symlink in the /usr farm: { target; kind; }; its path is the key in `links`.";
      type = "object";
      properties = {
        target = {
          type = "string";
          description = "Symlink target: a store path, or relative to the link (../sshd.service); for kind farm, a directory to link file by file.";
        };
        kind = {
          "$ref" = "#/$defs/linkKind";
        };
      };
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
    };

    argv = {
      description = "Program arguments after the executable: strings (no newline) and credential references, which render as `<prefix>%d/<credential>`.";
      type = "array";
      items = {
        anyOf = [
          { type = "string"; }
          { "$ref" = "#/$defs/credentialRef"; }
        ];
      };
    };

    appFiles = {
      description = "File name -> text, installed to `/usr/lib/<service>/<name>`; the name is relative (it cannot leave that directory), and a file holds no per-machine value.";
      type = "object";
      propertyNames = {
        type = "string";
        pattern = "^[A-Za-z0-9_+.-]+(/[A-Za-z0-9_+.-]+)*$";
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
        }
        {
          properties.unset = {
            const = true;
          };
          required = [ "unset" ];
        }
      ];
    };

    env = {
      description = "Environment variable name -> operation; the name is letters, digits and _, and does not start with a digit.";
      type = "object";
      propertyNames = {
        type = "string";
        pattern = "^[A-Za-z_][A-Za-z0-9_]*$";
      };
      additionalProperties = {
        "$ref" = "#/$defs/envOp";
      };
    };

    unitValue = {
      description = "A value on one line of a unit: a string with no control character (a newline would add a directive).";
      type = "string";
    };

    programName = {
      description = "An executable name in /usr/bin: letters, digits and _ @ . + -, never a path.";
      type = "string";
      pattern = "^[A-Za-z0-9_@.+-]+$";
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
    };

    credentialPrefix = {
      description = "A credential argument prefix: letters, digits, and _ = : / . , + -.";
      type = "string";
      pattern = "^[A-Za-z0-9_=:/.,+-]*$";
    };

    # modules/lib/service.nix
    service = {
      description = "A service: an app plus what only a unit has (scope, credentials, state, user, sandbox, ordering). Rendered as `ExecStart=/usr/bin/<program> <argv>` with the app's files under `/usr/lib/<name>/`. `user` is required for scope system and refused for scope user, which also refuses credentials.";
      type = "object";
      properties = {
        name = {
          "$ref" = "#/$defs/serviceName";
        };
        app = {
          "$ref" = "#/$defs/app";
        };
        scope = {
          "$ref" = "#/$defs/serviceScope";
        };
        credentials = {
          type = "object";
          additionalProperties = {
            "$ref" = "#/$defs/credentialId";
          };
          description = "Credential name -> credstore id (one name, never a path).";
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
      required = [
        "name"
        "app"
        "sandbox"
      ];
    };

    credentialId = {
      description = "A systemd credential id: letters, digits and _ . : @ -, one name in the credstore, never a path.";
      type = "string";
      pattern = "^[A-Za-z0-9_.:@-]+$";
    };

    stateDirectory = {
      description = "A StateDirectory= entry: one directory name under /var/lib (letters, digits, _ . -), not . or ...";
      type = "string";
      pattern = "^[A-Za-z0-9_.-]+$";
    };

    serviceScope = {
      description = "Which manager runs the unit: system (PID 1, /usr/lib/systemd/system) or user (systemd --user, /usr/lib/systemd/user; default WantedBy=default.target).";
      enum = [
        "system"
        "user"
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
      description = "One path component: letters, digits, _ . -.";
      type = "string";
      pattern = "^[A-Za-z0-9_.-]+$";
    };

    # modules/network/default.nix
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

  # Convert one adios option to a JSON Schema property. `declaredIn` is the
  # x-golconda-declaredIn value, or null.
  optionToSchema =
    opt: declaredIn:
    filterNulls (
      (typeToSchema opt.type)
      // {
        "x-golconda-declaredIn" = declaredIn;
        description = opt.description or null;
        default = if opt ? default && isPlainData opt.default then opt.default else null;
        examples = if opt ? example && isPlainData opt.example then [ opt.example ] else null;
      }
    );

  # path string under root, or null when it is outside it
  relativeTo =
    root: p:
    let
      s = builtins.unsafeDiscardStringContext (toString p);
      pre = "${root}/";
    in
    if root != null && substring 0 (stringLength pre) s == pre then
      substring (stringLength pre) (stringLength s) s
    else
      null;

  # Walk one module, returning { properties; } for its options. `ctx` is
  # { path; file; root; } of the module (file and root may be null).
  moduleToSchema =
    {
      path ? null,
      file ? null,
      root ? null,
    }:
    mod:
    let
      opts = mod.options or { };
      relFile = if file == null then null else relativeTo root file;
      declaredIn =
        name:
        if path == null then
          null
        else
          let
            pos = builtins.unsafeGetAttrPos name opts;
            line = if pos != null && relativeTo root pos.file == relFile then pos.line else null;
          in
          filterNulls {
            module = path;
            file = relFile;
            inherit line;
          };
      props = mapAttrs (n: o: optionToSchema o (declaredIn n)) opts;
      inputs = sort (a: b: a < b) (
        filter (p: p != null) (map (i: i.path or null) (attrValues (mod.inputs or { })))
      );
      # An option without a default is required: the evaluator throws on it.
      required = filter (n: !(opts.${n} ? default)) (attrNames opts);
    in
    filterNulls {
      type = "object";
      description = mod.name or null;
      properties = if props == { } then null else props;
      required = if required == [ ] then null else required;
      # the config table names options only: a misspelt option is not accepted
      additionalProperties = false;
      "x-golconda-inputs" = if path == null then null else inputs;
    };

  # Walk the module tree recursively, building the properties object.
  # Path is the current module path (list of strings).
  walkModules =
    ctx: path: mods:
    foldl' (
      acc: name:
      let
        mod = mods.${name};
        fullPath = path ++ [ name ];
        pathStr = "/" + builtins.concatStringsSep "/" fullPath;
        # This module's schema (if it has options)
        thisSchema =
          if mod ? options && mod.options != { } then
            {
              ${pathStr} = moduleToSchema {
                path = pathStr;
                file = ctx.files.${pathStr} or null;
                inherit (ctx) root;
              } mod;
            }
          else
            { };
        # Recurse into submodules
        subSchemas =
          if mod ? modules && mod.modules != { } then walkModules ctx fullPath mod.modules else { };
      in
      acc // thisSchema // subSchemas
    ) { } (attrNames mods);

  # The main export function.
  toJsonSchemaWith =
    {
      files ? [ ],
      root ? null,
    }:
    tree:
    let
      ctx = {
        inherit root;
        files = listToAttrs (
          map (m: {
            name = m.path;
            value = m.filePath;
          }) files
        );
      };
      allModules = walkModules ctx [ ] tree.modules;
    in
    {
      "$schema" = "https://json-schema.org/draft/2020-12/schema";
      "$id" = "https://golconda.dev/schema.json";
      title = "Golconda configuration";
      description = "Configuration options for Golconda modules: one table per module path.";
      type = "object";
      properties = allModules;
      required = [ "/system" ];
      additionalProperties = false;
      # every #/$defs/... reference resolves here (units, links, file, app, ...)
      "$defs" = typeRegistry;
    };
  toJsonSchema = toJsonSchemaWith { };
in
{
  inherit
    toJsonSchemaWith
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
