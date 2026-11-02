# The flake-incompat expression. Each per-system field is a function of
# { pkgs, platform, set, system } (default.nix argsFun); the rest is plain.
{ sources, self }:
let
  dev = import ./dev { inherit sources; };
  adios = import sources.adios;
  # The adios module tree (modules/); `tree { options = {...}; }` evaluates it.
  # Nothing per-system: a configuration passes its repkgs set as options."/pkgs".target.
  tree = import ../modules { inherit (adios) adios; };

  # mkSystem: the entry point for a complete Golconda system.
  # See lib/system.nix for the full interface.
  mkSystem = args: import ../lib/system.nix (args // { inherit sources; });

  docsFromSchema =
    let
      schemaLib = import ../lib/schema.nix { };
      moduleDocs = import ../lib/module-docs.nix { };
      docComments = import ../lib/doc-comments.nix { };
      modulePaths = (import ../lib/tree.nix { }).modulePaths ../modules;
    in
    moduleDocs.toMarkdown {
      schema = schemaLib.toJsonSchema (tree { });
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
      testConfig = version: {
        "/system" = {
          name = "boot-test";
          inherit version;
          fragments = [
            {
              name = "test-workload";
              files."/usr/lib/golconda/test-workload".text = "configured-workload\n";
              units."custom-workload.service" = ''
                [Unit]
                Description=Configured fragment regression test
                Before=boot-complete.target

                [Service]
                Type=oneshot
                ExecStart=/usr/bin/sh -ec 'test "$$(/usr/bin/cat /usr/lib/golconda/test-workload)" = configured-workload'
                RemainAfterExit=yes
              '';
              links."/usr/lib/systemd/system/boot-complete.target.requires/custom-workload.service" = {
                target = "../custom-workload.service";
                kind = "explicit";
              };
            }
          ];
          # The update test's release server: 10.0.2.2 is the host under QEMU user
          # networking, where the test serves the next release's disk.release/ with
          # `python3 -m http.server 8074` (docs/reference/image.md).
          updateSource = "http://10.0.2.2:8074/";
        };
        "/services/sshd" = {
          port = 22;
          # The test SSH public key: committed in tests/fixtures/snakeoil-ssh.pub.
          authorizedKeys = [ (builtins.readFile ../tests/fixtures/snakeoil-ssh.pub) ];
        };
      };

      # The test image for a host without Secure Boot (Hetzner Cloud): the kernel carries
      # the db certificate (/system.secureBoot = false); scripts/boot-test runs it on plain OVMF.
      noSecureBootConfig =
        version:
        let
          c = testConfig version;
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

      # the kernel: the repkgs fork's linux-kernel (a small bootable base) with Golconda's kconfig
      # fragment, which the override in nix/packages.nix applies to every `pkgs.linux-kernel`
      kernel = pkgs.linux-kernel;
    }
    # tests-<name>: a package's own test from tests/packages/ (they moved with the packages)
    // import ../tests/packages { inherit sources set; }
    // {

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
          config = testConfig "20261031.1";
          keys = throwawayKeys;
        }).smoke;

      # The test image without Secure Boot, and its next release for --next
      image-smoke-test-nosb =
        (imageChain {
          inherit system;
          config = noSecureBootConfig "20261031.1";
          keys = throwawayKeys;
        }).smoke;
      image-smoke-test-nosb-next =
        (imageChain {
          inherit system;
          config = noSecureBootConfig "20261031.2";
          keys = throwawayKeys;
        }).smoke;

      # The next release of the test image with the same throwaway keys: what
      # scripts/boot-test --next installs and boots, without --rotate.
      image-smoke-test-next =
        (imageChain {
          inherit system;
          config = testConfig "20261031.2";
          keys = throwawayKeys;
        }).smoke;

      # The next release of the test image, signed with a new db key: the loader, the UKI and
      # the verity root hash take rotatedKeys; the PCR policy key stays, so a credential sealed
      # by 20261031.1 still unseals. scripts/boot-test --next <this> --rotate installs it and
      # rotates the firmware's db (docs/design/bootloader.md).
      image-smoke-test-rotated =
        (imageChain {
          inherit system;
          config = testConfig "20261031.2";
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
          extra = {
            "/system".fragments = [ { packages = [ pkgs.jq ]; } ];
          };
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

    }
    // (
      if system == "x86_64-linux" then
        {
          # Cross-compiled usr-tree for aarch64: proves the platform argument flows through.
          # Built on x86_64, runs on aarch64. The jq binary in the output is an aarch64 ELF.
          # Visible only in packages.x86_64-linux (cross builds from x86_64 to aarch64).
          usr-tree-smoke-aarch64 =
            (mkSystem {
              inherit system;
              platform = "aarch64-linux";
              config = {
                "/system" = {
                  name = "smoke-aarch64";
                  version = "20261031.1";
                };
              };
              extra = {
                "/system".fragments = [
                  {
                    packages =
                      let
                        crossSet = import ./packages.nix {
                          inherit sources;
                          inherit system;
                          platform = "aarch64-linux";
                        };
                      in
                      [ crossSet.pkgs.jq ];
                  }
                ];
              };
            }).usrTree;
        }
      else
        { }
    );

  checks =
    { platform, set }:
    (import ./checks.nix {
      inherit sources self;
      double = platform.name;
    })
    // import ../tests/packages { inherit sources set; };

  # `iets fmt` / `nix fmt`: treefmt with every tool pinned (nix/dev/).
  formatter = { platform }: (dev platform.name).treefmt;

  devShells =
    { platform }:
    {
      default = (dev platform.name).shell;
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
