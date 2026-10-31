# Checks that run inside the sandbox. The iets lint needs the pins fetched and
# runs in CI as scripts/lint (iets.toml holds its strict levels).
{
  sources,
  self,
  double,
}:
let
  dev = import ./dev { inherit sources; } double;
  pkgs = import sources.nixpkgs-dev-only { system = double; };
  src = builtins.path {
    path = self;
    name = "golconda-src";
    filter = p: _: baseNameOf p != ".git" && !(pkgs.lib.hasPrefix "result" (baseNameOf p));
  };
  # the generated module pages (lib/module-docs.nix), by file name
  moduleDocs =
    let
      adiosPin = import sources.adios;
      tree = import ../modules { inherit (adiosPin) adios; };
      schemaLib = import ../lib/schema.nix { };
      moduleDocs' = import ../lib/module-docs.nix { };
      docComments = import ../lib/doc-comments.nix { };
      modulePaths = moduleDocs'.discoverModulePaths ../modules;
      md = moduleDocs'.toMarkdown {
        schema = schemaLib.toJsonSchema (tree { });
        inherit modulePaths docComments;
        inherit (schemaLib) typeRegistry;
        tree = tree { };
      };
    in
    pkgs.linkFarm "module-docs" (
      pkgs.lib.mapAttrsToList (name: text: {
        inherit name;
        path = pkgs.writeText name text;
      }) md.files
    );

  # Generated SUMMARY.md
  generatedSummary =
    let
      adiosPin = import sources.adios;
      tree = import ../modules { inherit (adiosPin) adios; };
      schemaLib = import ../lib/schema.nix { };
      moduleDocs' = import ../lib/module-docs.nix { };
      docComments = import ../lib/doc-comments.nix { };
      modulePaths = moduleDocs'.discoverModulePaths ../modules;
      md = moduleDocs'.toMarkdown {
        schema = schemaLib.toJsonSchema (tree { });
        inherit modulePaths docComments;
        inherit (schemaLib) typeRegistry;
        tree = tree { };
      };
    in
    pkgs.writeText "SUMMARY.md" md.summary;
in
{
  # formatting and Nix lints, as treefmt sees them
  treefmt = pkgs.runCommand "check-treefmt" { nativeBuildInputs = [ dev.treefmt ]; } ''
    cp -r ${src} src && chmod -R u+w src && cd src
    treefmt --ci --no-cache --tree-root .
    touch $out
  '';

  # the docs build; a broken include or diagram fails here
  docs =
    pkgs.runCommand "check-docs"
      {
        nativeBuildInputs = [
          dev.mdbook
          dev.mdbook-pele
        ];
      }
      ''
        # the book's first page includes ../README.md
        cp -r ${src}/docs docs && cp ${src}/README.md README.md && chmod -R u+w docs && cd docs
        # the reference pages that are generated, not committed
        mkdir -p reference/modules/generated
        cp -L ${moduleDocs}/*.md reference/modules/generated/
        # SUMMARY.md is generated, not committed
        cp ${generatedSummary} SUMMARY.md
        mdbook build -d $out
      '';

  # the generated module pages alone: `nix-build -A checks.x86_64-linux.module-docs`
  module-docs = moduleDocs;

  # nixpkgs is dev tooling only: the dev pin is referenced nowhere but nix/dev and nix/checks.nix
  boundary = pkgs.runCommand "check-boundary" { } ''
    cd ${src}
    if grep -rn --include='*.nix' 'nixpkgs-dev-only\|<nixpkgs>' . | grep -v '^./nix/dev/' | grep -v '^./nix/checks.nix' | grep -v '^./npins/'; then
      echo "nixpkgs referenced outside nix/dev (see docs/design/principles.md)" >&2
      exit 1
    fi
    touch $out
  '';

  # schema export produces valid JSON; evaluated at check eval time, not build time,
  # because the sandbox cannot fetch the sources. The schema JSON is written to $out.
  schema =
    let
      schemaLib = import ../lib/schema.nix { };
      tree = import ../modules { inherit (import sources.adios) adios; };
      schemaJson = builtins.toJSON (schemaLib.toJsonSchema (tree { }));
    in
    pkgs.writeText "schema.json" schemaJson;
}
