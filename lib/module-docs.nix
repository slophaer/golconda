# Markdown reference pages from the internal module schemas in lib/schema.nix,
# plus module doc comments, types documentation, and the module list for SUMMARY.md.
#
# `toMarkdown { moduleSchemas; modulePaths; docComments; typeRegistry; tree; }` returns
#   pages      module path ("/services/sshd") -> Markdown
#   index      Markdown listing every module
#   types      Markdown for the types page
#   summary    the module-pages lines of docs/SUMMARY.md (the rest is committed)
#   files      file name ("services-sshd.md", "index.md", "types.md") -> Markdown
#
# Pure Nix; docs/reference/modules/generated/ is written from `files`
# (scripts/docs, and the docs check in nix/checks.nix).
#
# Usage, for the module tree of this repository (nix/default.nix, nix/checks.nix):
#   (import ./module-docs.nix { }).forTree ((import ../modules { inherit (adios) adios; }) { })
_:
let
  on = import ../modules/lib/on.nix;
  inherit (builtins)
    attrNames
    concatStringsSep
    filter
    isAttrs
    listToAttrs
    map
    replaceStrings
    sort
    stringLength
    substring
    toJSON
    ;

  treeLib = import ./tree.nix { };

  join = concatStringsSep;
  sortStrings = sort (a: b: a < b);

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
      (on (s ? "x-golconda-opaque") [ s."x-golconda-opaque" ])
      ++ builtins.concatMap opaqueNames (
        (s.anyOf or [ ])
        ++ (s.oneOf or [ ])
        ++ (s.prefixItems or [ ])
        ++ (on (isAttrs (s.items or null)) [ s.items ])
        ++ (on (isAttrs (s.additionalProperties or null)) [ s.additionalProperties ])
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

  # The module files under the modules/ directory: lib/tree.nix, one walker for all.
  # Returns a list of { path = "/system"; filePath = ./system/default.nix; } records.
  discoverModulePaths = treeLib.modulePaths;

  # Generate a page for one module
  page =
    {
      path,
      schemaProps,
      docComment,
      hasImpl,
      hasTypes,
    }:
    let
      props = schemaProps.properties or { };
      names = attrNames props;
      hasOptions = names != [ ];
    in
    ''
      # `${path}`

    ''
    + (if docComment != null then docComment + "\n\n" else "")
    + ''
      This page is generated from the schema and module source; do not edit it.

    ''
    + (
      if hasOptions then
        ''
          ## Options

          | option | type | default | description |
          | ------ | ---- | ------- | ----------- |
        ''
        + join "\n" (map (n: row n props.${n}) names)
        + "\n"
        + opaqueNote schemaProps
      else
        "This module has no options.\n"
    )
    + (
      if hasImpl || hasTypes then
        "\n## Returns\n\n"
        + (if hasImpl then "This module has an `impl` that returns a value.\n" else "")
        + (if hasTypes then "This module exports `types`.\n" else "")
      else
        ""
    );

  # Generate the types documentation page
  typesPage =
    typeRegistry:
    let
      typeNames = sortStrings (attrNames typeRegistry);
      typeSection =
        name:
        let
          t = typeRegistry.${name};
          schema = builtins.removeAttrs t [ "description" ];
          schemaJson = toJSON schema;
        in
        ''
          ### `${name}`

          ${t.description}

          ```json
          ${schemaJson}
          ```

        '';
    in
    ''
      # Types

      Golconda's custom types from the schema registry (`lib/schema.nix`) and
      `modules/lib/*.nix`. This page is generated; do not edit it.

      See the [modules overview](../README.md) for how types are used.

    ''
    + join "\n" (map typeSection typeNames);

  # The module-pages lines of docs/SUMMARY.md: one entry per module, nested by depth,
  # then the types page. The rest of SUMMARY.md is hand-written and committed; the docs
  # check in nix/checks.nix fails when these lines and the file disagree, and
  # `scripts/docs` prints the lines to paste.
  generateSummary =
    modulePaths:
    let
      sortedPaths = sortStrings (map (m: m.path) modulePaths);
      # Indent based on depth: /system is depth 0, /services/sshd is depth 1
      depth = path: builtins.length (treeLib.pathComponents path) - 1;
      indent = d: join "" (builtins.genList (_: "  ") d);
      moduleEntry =
        path:
        let
          d = depth path;
        in
        "${indent (d + 1)}- [\`${path}\`](reference/modules/generated/${fileName path})";
      moduleEntries = join "\n" (map moduleEntry sortedPaths);
    in
    moduleEntries + "\n" + "${indent 1}- [Types](reference/modules/generated/types.md)\n";

  # The main export function.
  toMarkdown =
    {
      moduleSchemas,
      modulePaths,
      docComments,
      typeRegistry,
      tree,
    }:
    let
      allPaths = map (m: m.path) modulePaths;
      sortedPaths = sortStrings allPaths;

      # Build a lookup from path to file path
      pathToFile = listToAttrs (
        map (m: {
          name = m.path;
          value = m.filePath;
        }) modulePaths
      );

      getModule = treeLib.moduleAt tree;

      # Generate pages for all discovered modules
      pages = listToAttrs (
        map (
          path:
          let
            filePath = pathToFile.${path};
            schemaProps = moduleSchemas.${path} or { };
            docComment = docComments.moduleDoc filePath;
            mod = getModule path;
            hasImpl = mod ? impl;
            hasTypes = (mod.types or { }) != { };
          in
          {
            name = path;
            value = page {
              inherit
                path
                schemaProps
                docComment
                hasImpl
                hasTypes
                ;
            };
          }
        ) sortedPaths
      );

      index = ''
        # Module reference

        Generated from the schema and module sources. See the [types page](types.md) for
        type definitions.

        | module | options | has impl |
        | ------ | ------- | -------- |
      ''
      + join "\n" (
        map (
          p:
          let
            mod = getModule p;
            optCount = toString (builtins.length (attrNames (moduleSchemas.${p}.properties or { })));
            hasImpl = if mod ? impl then "yes" else "no";
          in
          "| [`${p}`](${fileName p}) | ${optCount} | ${hasImpl} |"
        ) sortedPaths
      )
      + "\n";

      types = typesPage typeRegistry;
      summary = generateSummary modulePaths;
    in
    {
      inherit
        pages
        index
        types
        summary
        ;
      files =
        listToAttrs (
          map (p: {
            name = fileName p;
            value = pages.${p};
          }) sortedPaths
        )
        // {
          "index.md" = index;
          "types.md" = types;
        };
    };

  # toMarkdown for Golconda's own modules: `tree` is the evaluated tree (`tree { }`)
  forTree =
    tree:
    let
      schemaLib = import ./schema.nix { };
    in
    toMarkdown {
      moduleSchemas = schemaLib.moduleSchemas tree;
      modulePaths = treeLib.modulePaths ../modules;
      docComments = import ./doc-comments.nix { };
      inherit (schemaLib) typeRegistry;
      inherit tree;
    };
in
{
  inherit
    forTree
    toMarkdown
    page
    typeOf
    fileName
    discoverModulePaths
    ;
}
