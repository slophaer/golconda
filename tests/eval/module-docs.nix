# Checks of the module documentation generator (lib/module-docs.nix): pages, index, types, doc comments.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  docComments,
  docs,
  f,
  hasInfix,
  moduleDocs,
  modulePaths,
  schemaLib,
  ...
}:
let
  inherit (builtins)
    all
    attrNames
    pathExists
    sort
    ;
in
[
  (check "module-docs: sshd page has the principals row and its default" (
    hasInfix "| `principals` | object of array of string | `{}` |" docs.pages."/services/sshd"
  ))
  (check "module-docs: sshd page has the port row with default 22" (
    hasInfix "| `port` | integer | `22` |" docs.pages."/services/sshd"
  ))
  (check "module-docs: index lists every module path" (
    all (p: hasInfix "[`${p}`](${docs.fileName.${p}})" docs.index) (attrNames docs.pages)
    &&
      attrNames docs.pages == [
        "/base"
        "/factory"
        "/imds"
        "/network"
        "/pkgs"
        "/security"
        "/services"
        "/services/sshd"
        "/system"
        "/trust"
        "/vars"
      ]
  ))
  (check "module-docs: files hold every page and the index and types" (
    attrNames docs.files == [
      "base.md"
      "factory.md"
      "imds.md"
      "index.md"
      "network.md"
      "pkgs.md"
      "security.md"
      "services-sshd.md"
      "services.md"
      "system.md"
      "trust.md"
      "types.md"
      "vars.md"
    ]
  ))
  (check "module-docs: SUMMARY.md links every module page" (
    let
      inherit (docs) summary;
      # index.md is not linked directly in SUMMARY; module pages are
      moduleFiles = builtins.filter (n: n != "index.md") (attrNames docs.files);
    in
    all (n: hasInfix "reference/modules/generated/${n})" summary) moduleFiles
  ))
  (check "module-docs: fixed sshd_config lines never appear as rows" (
    !(hasInfix "PasswordAuthentication" docs.pages."/services/sshd")
  ))
  (check "module-docs: opaque types are named and noted" (
    let
      p = moduleDocs.page {
        path = "/x";
        schemaProps.properties.o."x-golconda-opaque" = "mystery";
        docComment = null;
        hasImpl = false;
        hasTypes = false;
      };
    in
    hasInfix "opaque `mystery`" p && hasInfix "Opaque types are not described" p
  ))
  (check "module-docs: a pipe or angle bracket in text cannot break the table" (
    let
      p = moduleDocs.page {
        path = "/x";
        schemaProps.properties.o = {
          type = "string";
          description = "a|b <c>";
        };
        docComment = null;
        hasImpl = false;
        hasTypes = false;
      };
    in
    hasInfix "a\\|b &lt;c>" p
  ))
  (check "module-docs: sshd has no opaque option; package renders as a package" (
    !hasInfix "Opaque types" docs.pages."/services/sshd"
    && !hasInfix "`wrap`" docs.pages."/services/sshd"
    && hasInfix "| `package` | package | none |" docs.pages."/services/sshd"
  ))
  # New tests for module doc comments and types
  (check "module-docs: every discovered module has a page" (
    all (m: docs.pages ? ${m.path}) modulePaths
  ))
  (check "module-docs: every module file has a #! doc comment" (
    all (m: docComments.moduleDoc m.filePath != null) modulePaths
  ))
  (check "module-docs: discoverModulePaths finds each module file once" (
    let
      discoveredPaths = sort (a: b: a < b) (map (m: m.path) modulePaths);
    in
    discoveredPaths == [
      "/base"
      "/factory"
      "/imds"
      "/network"
      "/pkgs"
      "/security"
      "/services"
      "/services/sshd"
      "/system"
      "/trust"
      "/vars"
    ]
    && all (m: pathExists m.filePath) modulePaths
  ))
  (check "module-docs: types page lists every registry type" (
    let
      registryTypes = builtins.attrNames schemaLib.typeRegistry;
    in
    all (t: hasInfix "### `${t}`" docs.types) registryTypes
  ))
  (check "module-docs: every registry type has a description" (
    all (t: schemaLib.typeRegistry.${t} ? description) (builtins.attrNames schemaLib.typeRegistry)
  ))
  (check "module-docs: /system options have a description" (
    let
      schema = schemaLib.toJsonSchema (f.modules { });
    in
    builtins.all (o: o ? description && o.description != "") (
      builtins.attrValues schema.properties."/system".properties
    )
  ))
  (check "module-docs: vars page shows doc comment" (
    hasInfix "Installs the var runner" docs.pages."/vars"
  ))
  (check "module-docs: vars page shows it has an impl" (
    hasInfix "This module has an `impl`" docs.pages."/vars"
  ))
  (check "module-docs: services page has doc comment" (
    hasInfix "Container for service modules" docs.pages."/services"
  ))
]
