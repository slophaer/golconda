# Checks of the JSON Schema export: structure, defaults, the sshd table and the type-name parser.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  docs,
  f,
  hasInfix,
  hasPrefix,
  schemaLib,
  ...
}:
let
  inherit (builtins)
    all
    any
    attrNames
    concatMap
    elem
    elemAt
    hasAttr
    isAttrs
    isList
    stringLength
    substring
    ;
in
[
  # 5. JSON Schema export
  (check "schema: exports JSON Schema 2020-12" (
    let
      schema = schemaLib.toJsonSchema (f.modules { });
    in
    schema."$schema" == "https://json-schema.org/draft/2020-12/schema"
    && schema.type == "object"
    && schema ? properties
  ))
  (check "schema: every $ref resolves in $defs" (
    let
      schema = schemaLib.toJsonSchema (f.modules { });
      collectRefs =
        v:
        if isAttrs v then
          concatMap (n: if n == "$ref" then [ v.${n} ] else collectRefs v.${n}) (attrNames v)
        else if isList v then
          concatMap collectRefs v
        else
          [ ];
      refs = collectRefs schema;
      defs = schema."$defs";
    in
    refs != [ ]
    && all (r: hasPrefix "#/$defs/" r) refs
    && all (r: hasAttr (substring 8 (stringLength r) r) defs) refs
  ))
  (check "schema: the root needs /system and refuses unknown tables" (
    let
      schema = schemaLib.toJsonSchema (f.modules { });
    in
    schema.required == [ "/system" ] && schema.additionalProperties == false
  ))
  (check "schema: the system table needs name and version, with their grammars" (
    let
      schema = schemaLib.toJsonSchema (f.modules { });
      sys = schema.properties."/system";
    in
    elem "name" sys.required
    && elem "version" sys.required
    && sys.additionalProperties == false
    && sys.properties.name ? pattern
    && sys.properties.version ? pattern
  ))
  (check "schema: a fragment file is text or { text; mode; }" (
    let
      schema = schemaLib.toJsonSchema (f.modules { });
      files = schema."$defs".fragment.properties.files.additionalProperties;
      file = schema."$defs".file;
    in
    files."$ref" == "#/$defs/file" && any (b: b.type or null == "string") file.anyOf
  ))
  (check "schema: the environment operations are set and unset only" (
    let
      schema = schemaLib.toJsonSchema (f.modules { });
      op = schema."$defs".envOp;
      keys = map (b: attrNames b.properties) op.oneOf;
    in
    keys == [
      [ "set" ]
      [ "unset" ]
    ]
    && (elemAt op.oneOf 1).properties.unset.const == true
  ))
  (check "schema: a module table refuses an unknown option" (
    let
      schema = schemaLib.toJsonSchema (f.modules { });
    in
    schema.properties."/services/sshd".additionalProperties == false
  ))
  (check "schema: sshd module appears with its options" (
    let
      schema = schemaLib.toJsonSchema (f.modules { });
    in
    schema.properties ? "/services/sshd"
    && schema.properties."/services/sshd".properties ? port
    && schema.properties."/services/sshd".properties ? authorizedKeys
    && schema.properties."/services/sshd".properties ? principals
  ))
  (check "schema: principals is object of arrays of strings" (
    let
      schema = schemaLib.toJsonSchema (f.modules { });
      principals = schema.properties."/services/sshd".properties.principals;
    in
    principals.type == "object"
    && principals.additionalProperties.type == "array"
    && principals.additionalProperties.items.type == "string"
  ))
  (check "schema: port has default 22" (
    let
      schema = schemaLib.toJsonSchema (f.modules { });
      port = schema.properties."/services/sshd".properties.port;
    in
    port.type == "integer" && port.default == 22
  ))
  (check "schema: fixed sshd_config lines are not options" (
    let
      schema = schemaLib.toJsonSchema (f.modules { });
    in
    !(schema.properties."/services/sshd".properties ? PasswordAuthentication)
    && !(schema.properties."/services/sshd".properties ? UsePAM)
  ))
  (check "schema: system module has name, version, fragments" (
    let
      schema = schemaLib.toJsonSchema (f.modules { });
    in
    schema.properties ? "/system"
    && schema.properties."/system".properties ? name
    && schema.properties."/system".properties ? version
    && schema.properties."/system".properties ? fragments
  ))
  (check "schema: sshd has no wrap option and /pkgs.target is the set" (
    let
      schema = schemaLib.toJsonSchema (f.modules { });
    in
    !(schema.properties."/services/sshd".properties ? wrap)
    && schema.properties."/services/sshd".properties.package."x-golconda" == "package"
    && schema.properties."/pkgs".properties.target."x-golconda" == "set"
    && schema.properties."/pkgs".properties.build."x-golconda" == "set"
    && hasInfix "| `target` | set | none |" docs.pages."/pkgs"
  ))
  (check "schema: parseTypeName handles nested generics" (
    let
      p = schemaLib.parseTypeName "attrsOf<listOf<string>>";
    in
    p.base == "attrsOf" && p.args == [ "listOf<string>" ]
  ))
  (check "schema: parseTypeName handles union" (
    let
      p = schemaLib.parseTypeName "union<string,int>";
    in
    p.base == "union"
    &&
      p.args == [
        "string"
        "int"
      ]
  ))
  (check "schema: derivation maps to package marker" (
    let
      s = schemaLib.typeToSchemaByName "derivation";
    in
    s.type == "string" && s."x-golconda" == "package"
  ))
]
