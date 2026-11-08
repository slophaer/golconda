# Checks that run inside the sandbox. The iets lint needs the pins fetched and
# runs in CI as scripts/lint (iets.toml holds its strict levels).
#
# Each check is `run`: a content-addressed derivation whose builder is the repkgs seed's shell, as
# repkgs' own tests are, with tools from repkgs where it has them (python3, gnumake, coreutils) and
# the seed's nu, which Golconda's builders run. None uses the dev pin (nixpkgs); checks.boundary keeps
# it in nix/dev.
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

  # scripts/verify's steps on a scratch repository with fake nix-shell, nix-build, boot-test
  verify-script = run "verify-script" [ rp.coreutils rp.git rp.cpython ] ''
    export HOME=$TMPDIR
    sh ${src}/tests/verify/test.sh
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

  # Golconda's sources.toml as uptrack reads them: one it refuses (a key it does not know) fails
  # its whole run, which the console runs on packages/ for the newest upstream versions. uptrack
  # checks them itself, so this check keeps no list of its keys. `list` needs no network.
  uptrack-sources = run "uptrack-sources" [ rp.uptrack ] ''
    export HOME="$PWD" UPTRACK_ROOT=${src}/packages
    uptrack list > list.txt
    # it read them all: Golconda's own systemd is among them
    grep -q 'systemd' list.txt || { cat list.txt; exit 1; }
    touch $out
  '';

  # clippy over the console, tests and examples included, as a repkgs cargo build (console/checks)
  console-clippy = rp.golconda-console-clippy;

  # nixpkgs is dev tooling only: the dev pin is named nowhere but nix/dev in Nix files, and in
  # scripts only by scripts/boot-test, for the virtual machine repkgs does not build yet (QEMU's
  # system emulator, OVMF, swtpm, virt-firmware)
  boundary = run "boundary" [ ] ''
    cd ${src}
    # in pieces, so that this file does not name the pin
    n=nixpkgs
    pattern="$n-dev-only\|<$n>"
    if grep -rn --include='*.nix' "$pattern" . | grep -v '^./nix/dev/' | grep -v '^./npins/'; then
      echo "nixpkgs referenced in Nix outside nix/dev (docs/design/principles.md)" >&2
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
    # the console's validator (console/checks/schema-parity), the one golconda validate runs
    run "schema-parity" [ rp.golconda-schema-parity ] ''
      schema-parity ${schemaFile} ${fixtures}
      touch $out
    '';

  # the schema is valid JSON Schema 2020-12, by python's jsonschema (packages/python-jsonschema): a
  # whole implementation of the draft. repkgs has no python environment: PYTHONPATH holds the
  # site-packages of jsonschema and of each library it imports, for repkgs' cpython
  schema-metaschema =
    let
      libs = [
        rp.python-jsonschema
        rp.python-jsonschema-specifications
        rp.python-referencing
        rp.python-attrs
        rp.rpds-py
      ];
    in
    run "schema-metaschema" [ rp.cpython ] ''
      PYTHONPATH=$(printf '%s:' ${concatStringsSep " " (map (l: "${l}/lib/python3*/site-packages") libs)})
      export PYTHONPATH
      python3 ${src}/tests/schema/metaschema.py ${schemaFile}
      touch $out
    '';
}
