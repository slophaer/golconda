# JSON Schema 2020-12 export from the adios module tree.
#
# `toJsonSchema tree` walks the loaded tree and emits one JSON Schema object
# with `properties.<modulePath>` per module. Options become properties with
# their description, default/example when they are plain data, and a type
# derived from the korora type name.
#
# Korora does not expose `members` on struct types or `elems` on enum types.
# A local registry (lib/schema/registry-*.nix) lets Golconda's own types register their
# schema explicitly.
# Mark the gap with `x-golconda-opaque` for types that cannot be introspected.
#
# Provenance: every option carries `x-golconda-declaredIn` ({ module;
# file?; line? }: the module path that declares it, that module's file relative to
# the repo, and the line of the option in it, when the evaluator reports a position: iets does, nix does not), and every module `x-golconda-inputs`,
# the module paths it reads (its `inputs.<x>.path`, sorted): the edges of the module
# graph. `toJsonSchemaWith { files; root; }` knows the files: `files` maps a module
# path to its file path (lib/tree.nix `modulePaths`, as a list of
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

  # The grammars the typedefs match (modules/lib/grammar.nix): every pattern below
  # is one of them, anchored, so a type and its schema cannot disagree.
  grammar = import ../modules/lib/grammar.nix;
  pattern = name: grammar.anchored grammar.${name};
  # a name the type checks with a control-character rule besides its pattern
  noControl = {
    not.pattern = grammar.controlSchema;
  };

  # Registry of Golconda's custom types with their JSON Schema. Each entry is
  # keyed by the type's base name (__name) and maps to a JSON Schema fragment.
  # Types that are opaque or whose schema depends on their usage are not here;
  # they get x-golconda-opaque in the output.
  #
  # Every entry MUST have a `description` field; the test enforces this.
  # The entries live in lib/schema/registry-*.nix, one file per modules/lib file
  # (fragment, app, service, var) and one for the types of the module directories.
  typeRegistry =
    let
      args = { inherit grammar pattern noControl; };
    in
    builtins.foldl' (acc: f: acc // import f args) { } [
      ./schema/registry-modules.nix
      ./schema/registry-fragment.nix
      ./schema/registry-app.nix
      ./schema/registry-service.nix
      ./schema/registry-var.nix
    ];

  # The walk of a module tree is lib/tree.nix; these names stay here for the callers
  # (lib/config.nix, lib/system.nix) that read them from the schema library.
  inherit (import ./tree.nix { }) pathComponents moduleAt modulesOf;
  inherit (import ./components.nix { }) internalOptions roleOf;

  # A module that declares options: it has a table in the configuration and in the schema.
  hasOptions = mod: (mod.options or { }) != { };

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
    else if baseName == "option" && parsed.args != [ ] then
      {
        anyOf = [
          (typeToSchemaByName (head parsed.args))
          { type = "null"; }
        ];
      }
    else if baseName == "optionalAttr" && parsed.args != [ ] then
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
    typeToSchema opt.type
    // (if declaredIn == null then { } else { "x-golconda-declaredIn" = declaredIn; })
    // (if opt ? description then { inherit (opt) description; } else { })
    // (if opt ? default && isPlainData opt.default then { inherit (opt) default; } else { })
    // (if opt ? example && isPlainData opt.example then { examples = [ opt.example ]; } else { });

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
      # options mkSystem sets, never a document (lib/components.nix): not in the schema
      opts = removeAttrs (mod.options or { }) (internalOptions.${toString path} or [ ]);
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
      # Literal and computed defaults both make input optional.
      required = filter (n: !(opts.${n} ? default || opts.${n} ? defaultFunc)) (attrNames opts);
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

  # Internal docs and public inputs share the same per-module generation.
  moduleSchemasWith =
    {
      # [ { path; filePath; root?; } ]: a file's own `root` (a downstream repository's)
      # wins over `root`
      files ? [ ],
      root ? null,
    }:
    tree:
    let
      ctx = listToAttrs (
        map (m: {
          name = m.path;
          value = m;
        }) files
      );
    in
    listToAttrs (
      map (m: {
        name = m.path;
        value = moduleToSchema {
          inherit (m) path;
          file = ctx.${m.path}.filePath or null;
          root = ctx.${m.path}.root or root;
        } m.module;
      }) (filter (m: hasOptions m.module || roleOf m.path m.module == "component") (modulesOf tree))
    );
  moduleSchemas = moduleSchemasWith { };

  # /pkgs supplies Nix-only package sets, never a public configuration table.
  toJsonSchemaWith = context: tree: {
    "$schema" = "https://json-schema.org/draft/2020-12/schema";
    "$id" = "https://golconda.dev/schema.json";
    title = "Golconda configuration";
    description = "Configuration options for Golconda modules: one table per module path.";
    type = "object";
    properties = builtins.removeAttrs (moduleSchemasWith context tree) [ "/pkgs" ] // {
      # the project table (lib/config.nix): not a module
      golconda = {
        description = "Where the downstream repository's modules are, relative to this file. Optional; default \"modules\", used when it exists.";
        type = "object";
        properties.modules = {
          type = "string";
          description = "The module directory, mounted under /local.";
        };
        additionalProperties = false;
      };
    };
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
    moduleSchemasWith
    moduleSchemas
    typeToSchema
    typeToSchemaByName
    optionToSchema
    moduleToSchema
    typeRegistry
    parseTypeName
    parseTypeArgs
    isPlainData
    pathComponents
    moduleAt
    modulesOf
    hasOptions
    ;
}
