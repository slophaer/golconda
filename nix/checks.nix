# Checks that run inside the sandbox. The iets lint needs the pins fetched and
# runs in CI as scripts/lint (iets.toml holds its strict levels).
#
# Each check is `run`: a content-addressed derivation whose builder is the repkgs seed's shell, as
# repkgs' own tests are, with tools from repkgs where it has them (python3, gnumake, coreutils) and
# the seed's nu, which Golconda's builders run. None uses nixpkgs; checks.boundary keeps it out of
# every Nix file, script and pin.
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
  dev = import ./dev { inherit sources; } set;
  on = import ../modules/lib/on.nix;
  rp = set.pkgs;

  # python's jsonschema and the libraries it imports: PYTHONPATH holds their site-packages, for
  # repkgs' cpython (which has no python environment)
  jsonschemaPath =
    let
      libs = [
        rp.python-jsonschema
        rp.python-jsonschema-specifications
        rp.python-referencing
        rp.python-attrs
        rp.rpds-py
      ];
    in
    ''
      PYTHONPATH=$(printf '%s:' ${concatStringsSep " " (map (l: "${l}/lib/python3*/site-packages") libs)})
      export PYTHONPATH
    '';

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
          # cargo's build tree (cli/target)
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
    # the book's first page includes ../README.md, pinning.md includes an example from ../examples
    cp -r ${src}/docs docs && cp ${src}/README.md README.md && cp -r ${src}/examples examples
    chmod -R u+w docs && cd docs
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

  # the signer's key checks and signatures (tests/sign): a signature by the right key verifies
  # with the public half, one by another key does not, a mismatched key set is refused. The Nu
  # functions the signer runs (lib/image), under the seed's nu, with Golconda's openssl and gpg
  image-signer = run "image-signer" [ rp.openssl rp.gnupg ] ''
    export HOME=$TMPDIR
    nu --no-config-file --include-path ${src}/lib/image ${src}/tests/sign/test.nu
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
  # its whole run, which scripts run on packages/ for the newest upstream versions. uptrack
  # checks them itself, so this check keeps no list of its keys. `list` needs no network.
  uptrack-sources = run "uptrack-sources" [ rp.uptrack ] ''
    export HOME="$PWD" UPTRACK_ROOT=${src}/packages
    uptrack list > list.txt
    # it read them all: Golconda's own systemd is among them
    grep -q 'systemd' list.txt || { cat list.txt; exit 1; }
    # and the template's pin of Golconda, which a downstream repository updates with uptrack
    UPTRACK_ROOT=${src}/examples/pins uptrack list > example.txt
    grep -q ' golconda ' example.txt || { cat example.txt; exit 1; }
    touch $out
  '';

  # clippy over the command line, tests included, as a repkgs cargo build (cli/checks)
  cli-clippy = rp.golconda-cli-clippy;

  # nixpkgs is an input of nothing: no pin fetches it, and no Nix file or script names it as a
  # search path (angle brackets, -I, NIX_PATH) or as the old dev pin (docs/design/principles.md)
  boundary = run "boundary" [ ] ''
    cd ${src}
    # in pieces, so that this file does not match
    n=nixpkgs
    pattern="$n-dev-only\|<$n>\|-I $n=\|NIX_PATH=$n"
    if grep -rn --include='*.nix' "$pattern" .; then
      echo "nixpkgs referenced in Nix (docs/design/principles.md)" >&2
      exit 1
    fi
    if grep -rn "$pattern" scripts; then
      echo "nixpkgs referenced by a script (docs/design/principles.md)" >&2
      exit 1
    fi
    # a pin of nixpkgs: by its name, or by its URL (a channel tarball, the GitHub repository)
    if ls -d pins/*$n* 2>/dev/null || grep -rn -i "releases\.nixos\.org/$n\|github\.com/nixos/$n\|channels\.nixos\.org" pins; then
      echo "nixpkgs pinned in pins/ (docs/design/principles.md)" >&2
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

  # the schema is valid JSON Schema 2020-12, and it accepts each fixture exactly when Nix does
  # (tests/schema), by python's jsonschema (packages/python-jsonschema): a whole implementation of
  # the draft. repkgs has no python environment: PYTHONPATH holds the site-packages of jsonschema
  # and of each library it imports, for repkgs' cpython
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
    run "schema-parity" [ rp.cpython ] ''
      ${jsonschemaPath}
      python3 ${src}/tests/schema/validate.py ${schemaFile} ${fixtures}
      touch $out
    '';
}
# The eval tests that need the real package set (tests/real-packages: the SBOM, the image chain,
# the packages' build specs as repkgs resolves them). Evaluating this check runs them; they are
# about the x86_64 set, so the other platform's checks leave them out.
// on (double == "x86_64-linux") {
  real-packages = run "real-packages" [ ] (
    assert import ../tests/real-packages { inherit sources; };
    "touch $out"
  );

  # The test image's SBOM is valid CycloneDX 1.5 (the vendored schema, tests/fixtures/cyclonedx),
  # and the validator has teeth: it refuses the negative fixtures and the same SBOM with one
  # patch type broken. The SBOM is the evaluated document (builtins.toJSON), so no image is built.
  sbom-schema =
    let
      bom =
        (import ../lib/system.nix {
          inherit sources;
          platform = double;
          system = double;
          config = import ./test-config.nix { version = "20261031.1"; };
        }).sbom.bom;
      patched = c: c.pedigree.patches or [ ] != [ ];
      # a vacuous pass would prove nothing: the SBOM must carry patches, and the broken copy a
      # patch of a type CycloneDX does not know
      broken = bom // {
        components = map (
          c:
          if patched c then
            c
            // {
              pedigree = c.pedigree // {
                patches = map (p: p // { type = "bogus"; }) c.pedigree.patches;
              };
            }
          else
            c
        ) bom.components;
      };
      fixtures = "${src}/tests/fixtures/cyclonedx";
    in
    assert builtins.any patched bom.components;
    run "sbom-schema" [ rp.cpython ] ''
      ${jsonschemaPath}
      python3 ${src}/tests/sbom-schema/validate.py ${fixtures} \
        --valid ${toFile "sbom.json" (builtins.toJSON bom)} ${fixtures}/valid-patch.json \
        --invalid ${toFile "sbom-broken.json" (builtins.toJSON broken)} \
          ${fixtures}/invalid-patch-type.json ${fixtures}/invalid-no-bom-format.json
      touch $out
    '';
}
