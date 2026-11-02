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
    # the same set .gitignore excludes: generated docs, review scratch, results, direnv
    filter =
      p: _:
      let
        b = baseNameOf p;
        ignored = [
          ".git"
          ".review"
          ".direnv"
          "book"
          "generated"
        ];
      in
      !(builtins.elem b ignored) && !(pkgs.lib.hasPrefix "result" b);
  };

  # the generated Markdown (lib/module-docs.nix): the pages by file name, the SUMMARY lines
  md =
    let
      adiosPin = import sources.adios;
      tree = import ../modules { inherit (adiosPin) adios; };
      schemaLib = import ../lib/schema.nix { };
      docsLib = import ../lib/module-docs.nix { };
      docComments = import ../lib/doc-comments.nix { };
      modulePaths = (import ../lib/tree.nix { }).modulePaths ../modules;
    in
    docsLib.toMarkdown {
      moduleSchemas = schemaLib.moduleSchemas (tree { });
      inherit modulePaths docComments;
      inherit (schemaLib) typeRegistry;
      tree = tree { };
    };
  moduleDocs = pkgs.linkFarm "module-docs" (
    pkgs.lib.mapAttrsToList (name: text: {
      inherit name;
      path = pkgs.writeText name text;
    }) md.files
  );

  schemaFile =
    let
      schemaLib = import ../lib/schema.nix { };
      tree = import ../modules { inherit (import sources.adios) adios; };
    in
    pkgs.writeText "schema.json" (builtins.toJSON (schemaLib.toJsonSchema (tree { })));

  # The module-pages lines that docs/SUMMARY.md must contain
  generatedSummary = pkgs.writeText "summary-modules.md" md.summary;
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
        # SUMMARY.md is committed except that its module list must match the modules
        grep 'reference/modules/generated/' SUMMARY.md > have.txt || true
        if ! diff -u have.txt ${generatedSummary}; then
          echo "docs/SUMMARY.md: the module list is out of date; replace the lines that link" >&2
          echo "reference/modules/generated/ with the lines marked + (run scripts/docs to see them)" >&2
          exit 1
        fi
        rm have.txt
        mdbook build -d $out
      '';

  # every internal Markdown link and anchor resolves; scripts/check-doc-links says which does not
  docs-links = pkgs.runCommand "check-docs-links" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 ${src}/scripts/check-doc-links ${src}
    touch $out
  '';

  # the generated module pages alone: `nix-build -A checks.x86_64-linux.module-docs`
  module-docs = moduleDocs;

  # the /usr tree builder's link-target conversion: this runs the Nu function the
  # builder runs (lib/usr-tree/main.nu), not a Nix copy of it.
  usr-tree-test = pkgs.runCommand "check-usr-tree-test" { nativeBuildInputs = [ pkgs.nushell ]; } ''
    nu --no-config-file --include-path ${src}/lib/usr-tree ${src}/tests/usr-tree/test.nu
    touch $out
  '';

  usr-tree-builder = import ../tests/usr-tree { inherit pkgs src; };

  boot-log = pkgs.runCommand "check-boot-log" { } ''
    sh ${src}/tests/boot-log/test.sh
    sh ${src}/tests/boot-log/cli.sh
    touch $out
  '';

  # nixpkgs is dev tooling only: the dev pin is referenced nowhere but nix/dev and nix/checks.nix
  boundary = pkgs.runCommand "check-boundary" { } ''
    cd ${src}
    if grep -rn --include='*.nix' 'nixpkgs-dev-only\|<nixpkgs>' . | grep -v '^./nix/dev/' | grep -v '^./nix/checks.nix' | grep -v '^./npins/'; then
      echo "nixpkgs referenced outside nix/dev (see docs/design/principles.md)" >&2
      exit 1
    fi
    touch $out
  '';

  # the /etc/systemd/system link generator: first-boot links with an old store path
  # become the stable /usr/lib/systemd/system/<unit> path, and other shapes stay
  etc-systemd-links = pkgs.runCommand "check-etc-systemd-links" { } ''
    sh ${src}/tests/etc-systemd-links.sh ${src}/modules/base/golconda-etc-links
    touch $out
  '';

  # Export at evaluation time; the sandbox cannot fetch module sources.
  schema = schemaFile;

  schema-parity =
    let
      fixtures = pkgs.writeText "schema-fixtures.json" (
        builtins.toJSON (
          import ../tests/schema {
            inherit sources;
            platform = double;
          }
        )
      );
    in
    pkgs.runCommand "check-schema-parity"
      { nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.jsonschema ])) ]; }
      ''
        python3 ${src}/tests/schema/validate.py ${schemaFile} ${fixtures}
        touch $out
      '';
}
