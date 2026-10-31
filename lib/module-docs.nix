# Markdown reference pages from the JSON Schema that lib/schema.nix exports.
#
# `toMarkdown schema` returns
#   pages    module path ("/services/sshd") -> Markdown
#   index    Markdown listing every module
#   files    file name ("services-sshd.md", "index.md") -> Markdown
#   fileName module path -> file name
# Pure Nix; docs/reference/modules/generated/ is written from `files`
# (scripts/docs, and the docs check in nix/checks.nix). Only modules and their
# options are covered; the shared lib types are hand-written in README.md.
#
# Usage:
#   iets eval --raw -E '(import ./default.nix).docs-modules."/system"'
_:
let
  inherit (builtins)
    attrNames
    filter
    concatStringsSep
    isAttrs
    listToAttrs
    map
    replaceStrings
    substring
    stringLength
    toJSON
    ;

  join = concatStringsSep;

  # "/services/sshd" -> "services-sshd.md"
  fileName = path: replaceStrings [ "/" ] [ "-" ] (substring 1 (stringLength path) path) + ".md";

  # Type as the schema states it. `opaque` collects the names of opaque types.
  typeOf =
    s:
    if s ? "x-golconda-opaque" then
      "opaque `${s."x-golconda-opaque"}`"
    else if s ? anyOf then
      join " or " (map typeOf s.anyOf)
    else if s ? oneOf then
      "one of ${toString (builtins.length s.oneOf)} shapes"
    else if s ? enum then
      "enum " + join ", " (map (e: "`${toString e}`") s.enum)
    else if (s."x-golconda" or null) != null then
      s."x-golconda"
    else if (s.type or null) == "array" then
      if s ? prefixItems then
        "tuple of " + join ", " (map typeOf s.prefixItems)
      else
        "array of " + typeOf (s.items or { })
    else if (s.type or null) == "object" then
      if isAttrs (s.additionalProperties or null) then
        "object of " + typeOf s.additionalProperties
      else
        "object"
    else
      s.type or "any";

  opaqueNames =
    s:
    if !isAttrs s then
      [ ]
    else
      (if s ? "x-golconda-opaque" then [ s."x-golconda-opaque" ] else [ ])
      ++ builtins.concatMap opaqueNames (
        (s.anyOf or [ ])
        ++ (s.oneOf or [ ])
        ++ (s.prefixItems or [ ])
        ++ (if isAttrs (s.items or null) then [ s.items ] else [ ])
        ++ (if isAttrs (s.additionalProperties or null) then [ s.additionalProperties ] else [ ])
      );

  # One table cell: no newline, no unescaped pipe.
  cell = t: replaceStrings [ "\n" "|" "<" ] [ " " "\\|" "&lt;" ] t;

  defaultOf = s: if s ? default then "`${cell (toJSON s.default)}`" else "none";

  row =
    name: s: "| `${name}` | ${cell (typeOf s)} | ${defaultOf s} | ${cell (s.description or "")} |";

  opaqueNote =
    s:
    let
      props = s.properties or { };
      names = filter (n: opaqueNames props.${n} != [ ]) (attrNames props);
    in
    if names == [ ] then
      ""
    else
      "\nOpaque types are not described by the schema; see the type's source in `modules/lib/`. "
      + "Options with one: "
      + join ", " (map (n: "`${n}`") names)
      + ".\n";

  page =
    path: m:
    let
      props = m.properties or { };
      names = attrNames props;
    in
    ''
      # `${path}`

      Options of the `${path}` module. This page is generated from the schema
      (`iets eval --json -E '(import ./default.nix).schema'`); do not edit it.

      ## Options

    ''
    + (
      if names == [ ] then
        "This module has no options.\n"
      else
        ''
          | option | type | default | description |
          | ------ | ---- | ------- | ----------- |
        ''
        + join "\n" (map (n: row n props.${n}) names)
        + "\n"
    )
    + opaqueNote m;

  toMarkdown =
    schema:
    let
      mods = schema.properties or { };
      paths = attrNames mods;
      pages = listToAttrs (
        map (p: {
          name = p;
          value = page p mods.${p};
        }) paths
      );
      index = ''
        # Module reference

        Generated from the schema; the shared types are in the [overview](../README.md).

        | module | options |
        | ------ | ------- |
      ''
      + join "\n" (
        map (
          p:
          "| [`${p}`](${fileName p}) | ${
            toString (builtins.length (attrNames (mods.${p}.properties or { })))
          } |"
        ) paths
      )
      + "\n";
    in
    {
      inherit pages index;
      files =
        listToAttrs (
          map (p: {
            name = fileName p;
            value = pages.${p};
          }) paths
        )
        // {
          "index.md" = index;
        };
      fileName = listToAttrs (
        map (p: {
          name = p;
          value = fileName p;
        }) paths
      );
    };
in
{
  inherit toMarkdown typeOf fileName;
}
