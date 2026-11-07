# Checks that run inside the sandbox. The iets lint needs the pins fetched and
# runs in CI as scripts/lint (iets.toml holds its strict levels).
#
# Each check is `run`: a content-addressed derivation whose builder is the repkgs seed's shell, as
# repkgs' own tests are, with tools from repkgs where it has them (python3, gnumake, coreutils) and
# the seed's nu, which Golconda's builders run. The dev pin (nixpkgs) is left for the tools repkgs
# does not package yet: python's jsonschema (the dev-tools inventory in the knowledge base).
{
  sources,
  self,
  double,
  set,
}:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    elem
    substring
    toFile
    ;
  dev = import ./dev { inherit sources; } double set;
  nixpkgs = import sources.nixpkgs-dev-only { system = double; };
  rp = set.pkgs;

  # run NAME TOOLS SCRIPT: a check, built on the seed's shell (nix/run.nix)
  run = name: import ./run.nix set "check-${name}";

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
          # cargo's build tree (console/target)
          "target"
        ];
      in
      !(elem b ignored) && substring 0 6 b != "result";
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
  # one directory of the pages, each written by toFile (plain text, no store references)
  moduleDocs = run "module-docs" [ ] (
    "mkdir $out\n"
    + concatStringsSep "\n" (map (n: "ln -s ${toFile n md.files.${n}} $out/${n}") (attrNames md.files))
  );

  schemaFile =
    let
      schemaLib = import ../lib/schema.nix { };
      tree = import ../modules { inherit (import sources.adios) adios; };
    in
    toFile "schema.json" (builtins.toJSON (schemaLib.toJsonSchema (tree { })));

  # The module-pages lines that docs/SUMMARY.md must contain
  generatedSummary = toFile "summary-modules.md" md.summary;
in
{
  # formatting and Nix lints, as treefmt sees them
  treefmt = run "treefmt" [ dev.treefmt ] ''
    cp -r ${src} src && chmod -R u+w src && cd src
    treefmt --ci --no-cache --tree-root .
    touch $out
  '';

  # the docs build; a broken include or diagram fails here
  docs = run "docs" [ rp.mdbook rp.mdbook-pele ] ''
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
  docs-links = run "docs-links" [ rp.cpython ] ''
    python3 ${src}/scripts/check-doc-links ${src}
    touch $out
  '';

  # the generated module pages alone: `nix-build -A checks.x86_64-linux.module-docs`
  module-docs = moduleDocs;

  # the /usr tree builder's link-target conversion: this runs the Nu function the builder runs
  # (lib/usr-tree/main.nu) under the nu the builder runs, the seed's
  usr-tree-test = run "usr-tree-test" [ ] ''
    nu --no-config-file --include-path ${src}/lib/usr-tree ${src}/tests/usr-tree/test.nu
    touch $out
  '';

  usr-tree-builder = import ../tests/usr-tree {
    inherit run src;
    tools = [
      rp.cpython
      rp.coreutils
      rp.findutils
    ];
  };

  # GNU coreutils, as on a host: boot-test stops QEMU by signalling `timeout`, which GNU's passes
  # on to its child (toybox's does not)
  boot-log = run "boot-log" [ rp.coreutils ] ''
    sh ${src}/tests/boot-log/test.sh
    sh ${src}/tests/boot-log/cli.sh
    touch $out
  '';

  # the var runner's two modes on a scratch tree, with a stub systemd-creds (tests/vars)
  vars-runner = run "vars-runner" [ rp.coreutils ] ''
    sh ${src}/tests/vars/runner.sh
    touch $out
  '';

  # the kernel's package-local kbuild phases (packages/kernel/kbuild.nu) on a stub tree: no
  # Linux build, the real Nu module against the repkgs builder library, under the seed's nu
  kernel-builder = run "kernel-builder" [ rp.gnumake ] ''
    nu --no-config-file --include-path ${sources.repkgs}/builder ${src}/tests/kernel/test.nu
    touch $out
  '';

  # each ast-grep rule in lints/ against its cases in lints/tests/
  lint-rules = run "lint-rules" [ dev.ast-grep ] ''
    golconda-ast-grep test --skip-snapshot-tests
    touch $out
  '';

  # clippy over the console, tests included, as a repkgs cargo build (console/clippy)
  console-clippy = rp.golconda-console-clippy;

  # nixpkgs is dev tooling only: the dev pin is named nowhere but nix/dev and nix/checks.nix in
  # Nix files, and in scripts only by scripts/boot-test, for the virtual machine repkgs does not
  # build yet (QEMU's system emulator, OVMF, swtpm, virt-firmware)
  boundary = run "boundary" [ ] ''
    cd ${src}
    pattern='nixpkgs-dev-only\|<nixpkgs>'
    if grep -rn --include='*.nix' "$pattern" . | grep -v '^./nix/dev/' | grep -v '^./nix/checks.nix' | grep -v '^./npins/'; then
      echo "nixpkgs referenced in Nix outside nix/dev and nix/checks.nix (docs/design/principles.md)" >&2
      exit 1
    fi
    if grep -rn "$pattern" scripts | grep -v '^scripts/boot-test:'; then
      echo "nixpkgs referenced by a script other than scripts/boot-test (docs/design/principles.md)" >&2
      exit 1
    fi
    touch $out
  '';

  # the /etc/systemd/system link generator: first-boot links with an old store path
  # become the stable /usr/lib/systemd/system/<unit> path, and other shapes stay
  etc-systemd-links = run "etc-systemd-links" [ ] ''
    sh ${src}/tests/etc-systemd-links.sh ${src}/modules/base/golconda-etc-links
    touch $out
  '';

  # Export at evaluation time; the sandbox cannot fetch module sources.
  schema = schemaFile;

  schema-parity =
    let
      fixtures = toFile "schema-fixtures.json" (
        builtins.toJSON (
          import ../tests/schema {
            inherit sources;
            platform = double;
          }
        )
      );
    in
    # python's jsonschema is not packaged by repkgs (rpds-py, a Rust extension, among its needs)
    run "schema-parity" [ (nixpkgs.python3.withPackages (p: [ p.jsonschema ])) ] ''
      python3 ${src}/tests/schema/validate.py ${schemaFile} ${fixtures}
      touch $out
    '';
}
