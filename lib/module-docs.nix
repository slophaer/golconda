# Markdown reference pages from the JSON Schema that lib/schema.nix exports,
# plus module doc comments, types documentation, and SUMMARY.md generation.
#
# `toMarkdown { schema; modulePaths; docComments; typeRegistry; }` returns
#   pages      module path ("/services/sshd") -> Markdown
#   index      Markdown listing every module
#   types      Markdown for the types page
#   summary    generated SUMMARY.md content
#   files      file name ("services-sshd.md", "index.md", "types.md") -> Markdown
#   fileName   module path -> file name
#
# Pure Nix; docs/reference/modules/generated/ is written from `files`
# (scripts/docs, and the docs check in nix/checks.nix).
#
# Usage:
#   let
#     schemaLib = import ./schema.nix { };
#     tree = import ../modules { inherit (adios) adios; };
#     docComments = import ./doc-comments.nix { };
#     modulePaths = discoverModulePaths ../modules;
#   in
#   toMarkdown {
#     schema = schemaLib.toJsonSchema (tree { });
#     inherit modulePaths docComments;
#     typeRegistry = schemaLib.typeRegistry;
#   }
_:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    filter
    isAttrs
    listToAttrs
    map
    pathExists
    readDir
    replaceStrings
    sort
    stringLength
    substring
    toJSON
    ;

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

  # Discover module paths by walking the modules/ directory, mirroring adios.lib.importModules.
  # Returns a set of { path = "/system"; filePath = ./system/default.nix; } records.
  discoverModulePaths =
    rootPath:
    let
      # Recursively walk the directory
      walk =
        prefix: dir:
        let
          files = readDir dir;
          filenames = attrNames files;
        in
        builtins.concatMap (
          name:
          if name == "lib" then
            # Skip lib/ directory (shared types, not a module)
            [ ]
          else if files.${name} == "directory" then
            let
              subdir = dir + "/${name}";
              hasDefault = pathExists (subdir + "/default.nix");
              modulePath = prefix + "/" + name;
            in
            if hasDefault then
              [
                {
                  path = modulePath;
                  filePath = subdir + "/default.nix";
                }
              ]
              ++ walk modulePath subdir
            else
              [ ]
          else
            let
              m = builtins.match "(.+)\\.nix$" name;
            in
            if m == null || name == "default.nix" then
              [ ]
            else
              let
                moduleName = builtins.head m;
              in
              [
                {
                  path = prefix + "/" + moduleName;
                  filePath = dir + "/${name}";
                }
              ]
        ) filenames;
    in
    walk "" rootPath;

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

  # The fixed part of SUMMARY.md (hand-written content)
  summaryPrefix = ''
    # Summary

    [Golconda](index.md)

    # Design

    - [Principles](design/principles.md)
    - [Scope](design/scope.md)
    - [Architecture](design/architecture.md)
    - [Layout](design/layout.md)
    - [Boot](design/boot.md)
    - [Updates](design/updates.md)
    - [Trust](design/trust.md)
    - [Modules](design/modules.md)
    - [Configuration](design/config.md)
    - [Packaging](design/packaging.md)
    - [Comparison](design/comparison.md)

    # Reference

    - [Walkthrough](reference/walkthrough.md)
    - [Partitions and paths](reference/layout.md)
    - [Image artifacts](reference/image.md)
    - [Modules](reference/modules/README.md)
  '';

  summarySuffix = ''
    - [Configuration](reference/config.md)
    - [Commands](reference/cli.md)
    - [Outputs and inputs](reference/outputs.md)
    - [Glossary](reference/glossary.md)
  '';

  # Generate SUMMARY.md
  generateSummary =
    modulePaths:
    let
      sortedPaths = sortStrings (map (m: m.path) modulePaths);
      # Indent based on depth: /system is depth 1, /services/sshd is depth 2
      # builtins.split returns a mix of strings and match lists; filter only strings first
      depth =
        path:
        let
          parts = builtins.split "/" path;
          strings = filter builtins.isString parts;
          nonEmpty = filter (x: x != "") strings;
        in
        builtins.length nonEmpty - 1;
      indent = d: join "" (builtins.genList (_: "  ") d);
      moduleEntry =
        path:
        let
          d = depth path;
        in
        "${indent (d + 1)}- [\`${path}\`](reference/modules/generated/${fileName path})";
      moduleEntries = join "\n" (map moduleEntry sortedPaths);
    in
    summaryPrefix
    + moduleEntries
    + "\n"
    + "${indent 1}- [Types](reference/modules/generated/types.md)\n"
    + summarySuffix;

  # The main export function.
  toMarkdown =
    {
      schema,
      modulePaths,
      docComments,
      typeRegistry,
      tree,
    }:
    let
      mods = schema.properties or { };
      allPaths = map (m: m.path) modulePaths;
      sortedPaths = sortStrings allPaths;

      # Build a lookup from path to file path
      pathToFile = listToAttrs (
        map (m: {
          name = m.path;
          value = m.filePath;
        }) modulePaths
      );

      # Get module from tree by path
      getModule =
        path:
        let
          splitParts = builtins.split "/" path;
          strings = filter builtins.isString splitParts;
          parts = filter (x: x != "") strings;
          walk = mod: ps: if ps == [ ] then mod else walk mod.modules.${builtins.head ps} (builtins.tail ps);
        in
        walk tree parts;

      # Generate pages for all discovered modules
      pages = listToAttrs (
        map (
          path:
          let
            filePath = pathToFile.${path};
            schemaProps = mods.${path} or { };
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
            optCount = toString (builtins.length (attrNames (mods.${p}.properties or { })));
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
      # fileName as a set mapping path -> file name (for backward compatibility with tests)
      fileName = listToAttrs (
        map (p: {
          name = p;
          value = fileName p;
        }) sortedPaths
      );
      inherit modulePaths;
    };
in
{
  inherit
    toMarkdown
    typeOf
    fileName
    discoverModulePaths
    ;
}
