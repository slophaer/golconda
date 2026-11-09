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

  # The image chain over one system, as a release builds it (lib/image/chain.nix).
  imageChain = import ../lib/image/chain.nix { inherit sources mkSystem imageLib; };

  # mkImage { config; keys; pcrKeys ? keys; indexKeys ? keys; system ? builtins.currentSystem; } →
  #   { erofs; verity; initrd; uki; loader; disk; release; }
  # `config` is what lib.mkSystem takes (a TOML path or options); `keys` is the directory
  # in the layout lib/image/chain.nix describes. `indexKeys` names a second directory, read for release/ only (the
  # release key that signs SHA256SUMS), for a key set made before it had one. No smoke: it would link the private keys into its output.
  mkImage = args: builtins.removeAttrs (imageChain args) [ "smoke" ];
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

      # the base system of examples/server.toml, as lib.mkSystem makes it
      imageSmoke = imageChain {
        inherit system;
        config = ../examples/server.toml;
        keys = throwawayKeys;
      };

      # Boot test image: authorizedKeys for testing SSH login.
      # The test SSH keypair is a committed test fixture (tests/fixtures/snakeoil-ssh*).
      # See tests/fixtures/README.md for why both keys are committed.
      # adminVars: the release after the bootstrap. The first release logs in with the plain
      # test key and trusts the test user CA; scripts/boot-test pushes the host certificate and the
      # revocation list to it with `golconda vars`, and the next release turns both on
      # (the bootstrap in docs/design/trust.md).
      testConfig =
        {
          version,
          adminVars ? false,
        }:
        {
          # the configured workload is a downstream module (tests/fixtures/image-workload/modules)
          golconda.modules = ../tests/fixtures/image-workload/modules;
          "/local/test-workload" = { };
          "/system" = {
            name = "boot-test";
            inherit version;
            # The update test's release server: 169.254.169.2 is the gateway of the test's QEMU
            # user network (169.254.169.0/24, for --imds: the metadata address 169.254.169.254
            # must be on the link), and the test forwards the guest's connections to port 8074
            # there to a per-run HTTP server of the next release's disk.release/ (guestfwd;
            # docs/reference/image.md). systemd-imds locks only 169.254.169.254.
            updateSource = "http://169.254.169.2:8074/";
          };
          "/services/sshd" = {
            port = 22;
            # The test SSH public key: committed in tests/fixtures/snakeoil-ssh.pub.
            authorizedKeys = [ (builtins.readFile ../tests/fixtures/snakeoil-ssh.pub) ];
            # the test user CA (tests/fixtures/snakeoil-user-ca.pub): a certificate for this
            # principal logs in as root
            trustedUserCAKeys = [ (builtins.readFile ../tests/fixtures/snakeoil-user-ca.pub) ];
            principals.root = [ "boot-test-admin" ];
          }
          // (on adminVars {
            hostCertificate = true;
            revokedKeys = true;
          });
          # cloud metadata: QEMU's DMI names no cloud, so no import runs and no unit fails; a
          # boot test that fakes a cloud's DMI and endpoint imports from it
          "/imds" = { };
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

      # The image chain (lib/image) over the /base system: erofs, verity, initrd, UKI, disk, and
      # the proofs in proof.txt. Keys are throwaways made in the store; a release signs with the
      # deployment's keys (lib.mkImage). image-smoke-<step> exposes each step on its own.
      image-smoke = imageSmoke.smoke;
      image-smoke-erofs = imageSmoke.erofs;
      image-smoke-verity = imageSmoke.verity;
      image-smoke-initrd = imageSmoke.initrd;
      image-smoke-uki = imageSmoke.uki;
      image-smoke-disk = imageSmoke.disk;
      image-smoke-loader = imageSmoke.loader;

      image-smoke-test =
        (imageChain {
          inherit system;
          config = testConfig { version = "20261031.1"; };
          keys = throwawayKeys;
        }).smoke;

      # The test image without Secure Boot, and its next release for --next
      image-smoke-test-nosb =
        (imageChain {
          inherit system;
          config = noSecureBootConfig { version = "20261031.1"; };
          keys = throwawayKeys;
        }).smoke;
      image-smoke-test-nosb-next =
        (imageChain {
          inherit system;
          config = noSecureBootConfig {
            version = "20261031.2";
            adminVars = true;
          };
          keys = throwawayKeys;
        }).smoke;

      # The next release of the test image with the same throwaway keys: what
      # scripts/boot-test --next installs and boots, without --rotate.
      image-smoke-test-next =
        (imageChain {
          inherit system;
          config = testConfig {
            version = "20261031.2";
            adminVars = true;
          };
          keys = throwawayKeys;
        }).smoke;

      # The next release of the test image, signed with a new db key: the loader, the UKI and
      # the verity root hash take rotatedKeys; the PCR policy key stays, so a credential sealed
      # by 20261031.1 still unseals. scripts/boot-test --next <this> --rotate installs it and
      # rotates the firmware's db (docs/design/bootloader.md).
      image-smoke-test-rotated =
        (imageChain {
          inherit system;
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
  platforms = import "${sources.repkgs}/nix/platforms.nix";

  # lib: Nix library functions for building Golconda systems.
  #   (import ./default.nix).lib.mkSystem { config = ./server.toml; }
  #   (import ./default.nix).lib.mkImage { config = ./server.toml; keys = "/srv/golconda-keys"; }
  lib = { inherit mkSystem mkImage; };
}
