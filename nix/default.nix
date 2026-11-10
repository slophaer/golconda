# The flake-incompat expression. Each per-system field is a function of
# { pkgs, platform, set, system } (default.nix argsFun); the rest is plain.
{ sources, self }:
let
  on = import ../modules/lib/on.nix;
  dev = import ./dev { inherit sources; };
  adios = import sources.adios;
  # The adios module tree (modules/); `tree { options = {...}; }` evaluates it.
  # Nothing per-system: a configuration passes its repkgs set as options."/pkgs".target.
  tree = import ../modules { inherit (adios) adios; };

  # mkSystem: the entry point for a complete Golconda system.
  # See lib/system.nix for the full interface.
  # A path is the configuration alone: mkSystem ./server.toml.
  mkSystem =
    args:
    import ../lib/system.nix (
      (if builtins.isPath args then { config = args; } else args) // { inherit sources; }
    );

  docsFromSchema =
    let
      schemaLib = import ../lib/schema.nix { };
      moduleDocs = import ../lib/module-docs.nix { };
      docComments = import ../lib/doc-comments.nix { };
      modulePaths = (import ../lib/tree.nix { }).modulePaths ../modules;
    in
    moduleDocs.toMarkdown {
      moduleSchemas = schemaLib.moduleSchemas (tree { });
      inherit modulePaths docComments;
      inherit (schemaLib) typeRegistry;
      tree = tree { };
    };
  imageLib = import ../lib/image { };

  # The image chain over one system, unsigned, as a release builds it (lib/image/chain.nix).
  imageChain = import ../lib/image/chain.nix { inherit sources mkSystem imageLib; };

  # mkImage { config; publicKeys; pcrPublicKeys ? publicKeys; indexPublicKeys ? publicKeys;
  #   system ? builtins.currentSystem; } →
  #   { unsigned; usrTree; initrd; signer; pkgs; signWithTestKeys; }
  # `config` is what lib.mkSystem takes (a TOML path or options); `publicKeys` is the key set's
  # directory, of which the chain reads the public halves only (lib/image/chain.nix). Nothing is
  # signed: `golconda release build` runs `unsigned`'s signer with the private keys, outside the
  # store. `signWithTestKeys` signs in the store, for throwaway keys only.
  mkImage = imageChain;
in
{
  packages =
    {
      pkgs,
      set,
      system,
      ...
    }:
    let
      throwawayKeys = imageLib.throwawayKeys {
        inherit pkgs;
        buildSystem = system;
      };

      # A test image: the chain over `config` with the public halves of throwaway keys, signed
      # in the store by the signer a release host runs (lib/image/signer.nix), with its proofs
      # (lib/image/smoke.nix). `pcrKeys` and `indexKeys` default to `keys`.
      testImage =
        {
          config,
          keys ? throwawayKeys,
          pcrKeys ? keys,
          indexKeys ? keys,
        }:
        let
          chain = imageChain {
            inherit system config;
            publicKeys = keys.public;
            pcrPublicKeys = pcrKeys.public;
            indexPublicKeys = indexKeys.public;
          };
          signed = chain.signWithTestKeys { inherit keys pcrKeys indexKeys; };
        in
        chain
        // {
          inherit signed;
          smoke = imageLib.smoke {
            inherit (chain)
              unsigned
              pkgs
              imageId
              version
              ;
            inherit signed;
            keys = keys.public;
            buildSystem = system;
          };
        };

      # the base system of examples/server.toml, as lib.mkSystem makes it
      imageSmoke = testImage { config = ../examples/server.toml; };

      # Boot test image: see nix/test-config.nix.
      testConfig = import ./test-config.nix;
      smokeTest = testImage {
        config = testConfig { version = "20261031.1"; };
      };

      # The test image for a host without Secure Boot (Hetzner Cloud): the kernel carries
      # the db certificate (/system.secureBoot = false); scripts/boot-test runs it on plain OVMF.
      noSecureBootConfig =
        args:
        let
          c = testConfig args;
        in
        c
        // {
          "/system" = c."/system" // {
            secureBoot = false;
          };
        };

      # The key rotation test's new db key: a second throwaway set
      # (docs/design/bootloader.md)
      rotatedKeys = imageLib.throwawayKeys {
        inherit pkgs;
        buildSystem = system;
        variant = "rotated";
      };
    in
    {
      # repkgs' own Nix package (stock Nix with a relocation patch), built by repkgs, so it
      # needs a daemon with CA and dynamic derivations first (docs/reference/build-host.md)
      inherit (pkgs) nix;
      # the command line (cli/), built by repkgs like nix
      inherit (pkgs) golconda-cli;
      # what golconda vars encrypts with, on PATH beside it
      inherit (pkgs) age;
      # copies a release to its update source (golconda release publish), on PATH beside golconda
      inherit (pkgs) rclone;
      # repkgs' update tool: the packages' upstream check runs it
      inherit (pkgs) uptrack;
      # an S3-compatible store for the release tool's tests
      inherit (pkgs) garage;
      # what scripts/provision-esp runs on the build host (scripts/tools.sh): our systemd-creds,
      # sfdisk, mtools and python, not nixpkgs'
      inherit (pkgs)
        systemd
        mtools
        util-linux
        cpython
        ;
      # what scripts/make-keys runs (scripts/tools.sh): openssl for the db and PCR keys, and
      # Golconda's gnupg, the gpg that systemd-pull checks the release index with on the image
      inherit (pkgs) openssl gnupg;
      # the dev shell's book tools (scripts/docs), and what scripts/tool runs (scripts/tools.sh)
      inherit (pkgs) mdbook mdbook-pele hcloud;
    }
    # tests-<name>: a package's own test from tests/packages/ (they moved with the packages)
    // import ../tests/packages { inherit sources set; }
    // (on pkgs.linux-kernel.supported {
      # OS outputs need the local kernel. Do not advertise unsupported image or /usr trees.
      # nix/packages.nix applies the policy fragment to every `pkgs.linux-kernel`.
      kernel = pkgs.linux-kernel;

      # The image chain (lib/image) over the /base system, signed in the store with throwaway
      # keys, and the proofs in proof.txt. A release signs with the deployment's keys outside the
      # store (lib.mkImage, `golconda release build`). The parts: the unsigned outputs, the
      # initrd, the signer, and the signed disk and release directory.
      image-smoke = imageSmoke.smoke;
      image-smoke-unsigned = imageSmoke.unsigned;
      image-smoke-initrd = imageSmoke.initrd;
      image-smoke-signer = imageSmoke.signer;
      image-smoke-signed = imageSmoke.signed;

      image-smoke-test = smokeTest.smoke;

      # The test image's initrd is bit-reproducible: Nix builds its derivation again, with one
      # variable more that lib/image/initrd.nu does not read, and the two initrd.cpio.zst are the
      # same bytes. When they differ, tests/initrd/newc-diff.py names the cpio header fields that
      # do. scripts/verify builds it after the image (an initrd build takes about 90 s, too long
      # for scripts/lint).
      initrd-reproducible =
        let
          inherit (smokeTest) initrd;
          again = derivation (initrd.drvAttrs // { reproducibilityRun = "2"; });
          newcDiff = builtins.path {
            path = ../tests/initrd/newc-diff.py;
            name = "newc-diff.py";
          };
        in
        import ./run.nix set "check-initrd-reproducible" [ pkgs.zstd ] ''
          if cmp ${initrd}/initrd.cpio.zst ${again}/initrd.cpio.zst; then
            touch $out
            exit 0
          fi
          zstd -q -dc ${initrd}/initrd.cpio.zst > $TMPDIR/a.cpio
          zstd -q -dc ${again}/initrd.cpio.zst > $TMPDIR/b.cpio
          python3 ${newcDiff} $TMPDIR/a.cpio $TMPDIR/b.cpio || true
          exit 1
        '';

      # The test image without Secure Boot, and its next release for --next
      image-smoke-test-nosb =
        (testImage {
          config = noSecureBootConfig { version = "20261031.1"; };
        }).smoke;
      image-smoke-test-nosb-next =
        (testImage {
          config = noSecureBootConfig {
            version = "20261031.2";
            adminVars = true;
          };
        }).smoke;

      # The next release of the test image with the same throwaway keys: what
      # scripts/boot-test --next installs and boots, without --rotate.
      image-smoke-test-next =
        (testImage {
          config = testConfig {
            version = "20261031.2";
            adminVars = true;
          };
        }).smoke;

      # The next release of the test image, signed with a new db key: the loader, the UKI and
      # the verity root hash take rotatedKeys; the PCR policy key stays, so a credential sealed
      # by 20261031.1 still unseals. scripts/boot-test --next <this> --rotate installs it and
      # rotates the firmware's db (docs/design/bootloader.md).
      image-smoke-test-rotated =
        (testImage {
          config = testConfig {
            version = "20261031.2";
            adminVars = true;
          };
          keys = rotatedKeys;
          pcrKeys = throwawayKeys;
          # the running image trusts only its own release key: a db rotation keeps it
          indexKeys = throwawayKeys;
        }).smoke;

      # Smoke test for the /usr tree builder: base system + jq via mkSystem.
      usr-tree-smoke =
        (mkSystem {
          inherit system;
          platform = system;
          config = {
            "/system" = {
              name = "smoke";
              version = "20261031.1";
            };
          };
          extraFragments = [
            {
              name = "/smoke/jq";
              packages = [ pkgs.jq ];
            }
          ];
        }).usrTree;

      # Smoke test for /base alone: no extra fragments, just the base packages.
      # Verifies: no absolute symlinks, no GNU coreutils, base packages only.
      usr-tree-base-smoke =
        (mkSystem {
          inherit system;
          platform = system;
          config = {
            "/system" = {
              name = "base-smoke";
              version = "20261031.1";
            };
          };
        }).usrTree;

    });

  checks =
    { platform, set }:
    (import ./checks.nix {
      inherit sources self set;
      double = platform.name;
    })
    // import ../tests/packages { inherit sources set; };

  # `iets fmt` / `nix fmt`: treefmt with every tool pinned (nix/dev/).
  formatter = { set }: (dev set).treefmt;

  devShells =
    { set }:
    {
      default = (dev set).shell;
    };

  # The adios module tree (modules/). `modules { options = {...}; }` evaluates it.
  modules = tree;

  # JSON Schema 2020-12 export of the module tree. Not per-system: the schema
  # depends only on the module definitions, not on any packages.
  #   iets eval --json -E '(import ./default.nix).schema'
  schema = (import ../lib/schema.nix { }).toJsonSchema (tree { });

  # Markdown reference pages generated from the schema (lib/module-docs.nix).
  #   iets eval --raw -E '(import ./default.nix).docs-modules."/system"'
  docs-modules = docsFromSchema.pages;

  # The same pages by file name (services-sshd.md, index.md, types.md); scripts/docs writes these.
  docs-pages = docsFromSchema.files;

  # The module-pages lines of docs/SUMMARY.md (the file is committed; scripts/docs checks them).
  docs-summary = docsFromSchema.summary;

  # Module paths discovered from modules/ directory.
  docs-module-paths = docsFromSchema.modulePaths;

  # TOML configuration loader: a document in, checked options out. Returns
  # { loadConfig; loadConfigText; checkOptions; optionError; validPaths; }.
  # It applies nothing: lib.mkSystem is the one entry point that does.
  #   (import ./default.nix).configLib.loadConfig ./config.toml
  configLib = import ../lib/config.nix { tree = tree { }; };

  # The platforms table (repkgs nix/platforms.nix), for callers that need all target names.
  # Not per-system: the same table on every build host.
  platforms = import (sources.repkgs + "/nix/platforms.nix");

  # lib: Nix library functions for building Golconda systems.
  #   (import ./default.nix).lib.mkSystem { config = ./server.toml; }
  #   (import ./default.nix).lib.mkImage { config = ./server.toml; publicKeys = ./keys; }
  #   (import ./default.nix).lib.readPins ./pins   # { <name> = tree; } from uptrack pins (lib/pins.nix)
  # nix flake init -t <golconda>: a repository with server.toml and a flake.nix that takes
  # Golconda as its input (docs/reference/pinning.md)
  templates.default = {
    path = ../templates/default;
    description = "A Golconda system: server.toml, and a flake with Golconda as its input";
  };

  lib = {
    inherit mkSystem mkImage;
    readPins = (import ../lib/pins.nix).read;
  };
}
