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
      modulePaths = moduleDocs.discoverModulePaths ../modules;
    in
    moduleDocs.toMarkdown {
      schema = schemaLib.toJsonSchema (tree { });
      inherit modulePaths docComments;
      inherit (schemaLib) typeRegistry;
      tree = tree { };
    };
  imageLib = import ../lib/image { };
in
{
  packages =
    {
      pkgs,
      system,
      platform,
      ...
    }:
    let
      # The image chain over one system, as a release builds it (lib/image). The signed loader
      # comes first: the /usr tree carries it (lib/image/loader.nix loaderFragment), and the disk
      # step checks that the ESP gets the same file. `sbKeys` sign the loader, the UKI and the
      # verity root hash (the db key: the kernel checks the signature against the firmware db,
      # docs/design/trust.md); `pcrKeys` sign the PCR 11 policy; `keys` is the smoke's keys/
      # link, the db certificate scripts/boot-test enrols.
      imageChain =
        {
          config,
          sbKeys,
          pcrKeys ? sbKeys,
          keys ? sbKeys,
        }:
        let
          sbKey = "${sbKeys}/secureboot/db.key";
          sbCert = "${sbKeys}/secureboot/db.crt";
          loader = imageLib.loader {
            inherit
              pkgs
              platform
              sbKey
              sbCert
              ;
            buildSystem = system;
          };
          sys = mkSystem {
            inherit system config;
            platform = system;
            extra."/system".fragments = [ (imageLib.loaderFragment { inherit loader platform; }) ];
          };
          args = {
            imageId = sys.name;
            inherit (sys) version platform pkgs;
            buildSystem = system;
          };
          erofs = imageLib.erofs (args // { inherit (sys) usrTree; });
          verity = imageLib.verity (
            args
            // {
              inherit erofs;
              key = sbKey;
              cert = sbCert;
            }
          );
          initrd = imageLib.initrd (args // { usrTree = imageLib.initrdTree args; }); # not sys.usrTree
          uki = imageLib.uki (
            args
            // {
              inherit
                initrd
                verity
                sbKey
                sbCert
                ;
              inherit (sys) usrTree;
              pcrKey = "${pcrKeys}/pcr/pcr.key";
              pcrPublicKey = "${pcrKeys}/pcr/pcr.pub";
              # No cmdlineExtra: every image boots the production cmdline (image/uki.nix carries
              # `rw`, so the root is writable before the ssh host key var runs). To watch a boot:
              # cmdlineExtra = "systemd.log_level=debug systemd.log_target=console
              # systemd.journald.forward_to_console=1";
            }
          );
          disk = imageLib.disk (
            args
            // {
              inherit
                erofs
                verity
                uki
                loader
                ;
              inherit (sys) usrTree;
            }
          );
        in
        {
          inherit
            erofs
            verity
            initrd
            uki
            loader
            disk
            ;
          smoke = imageLib.smoke (
            args
            // {
              inherit
                erofs
                verity
                initrd
                uki
                disk
                keys
                ;
            }
          );
        };

      throwawayKeys = imageLib.throwawayKeys {
        inherit pkgs;
        buildSystem = system;
      };

      # the base system of examples/server.toml, as lib.mkSystem makes it
      imageSmoke = imageChain {
        config = ../examples/server.toml;
        sbKeys = throwawayKeys;
      };

      # Boot test image: authorizedKeys for testing SSH login.
      # The test SSH keypair is a committed test fixture (tests/fixtures/snakeoil-ssh*).
      # See tests/fixtures/README.md for why both keys are committed.
      testConfig = version: {
        "/system" = {
          name = "boot-test";
          inherit version;
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

      # The key rotation test's new db key: a second throwaway set
      # (docs/design/bootloader.md)
      rotatedKeys = imageLib.throwawayKeys {
        inherit pkgs;
        buildSystem = system;
        variant = "rotated";
      };
    in
    {
      # the patched Nix daemon repkgs needs (CA + dynamic derivations); builders run it
      inherit (pkgs) nix;

      # the kernel: the fork's base with Golconda's config fragment (packages/kernel)
      kernel = import ../packages/kernel { inherit pkgs; };

      # The image chain (lib/image) over the /base system: erofs, verity, initrd, UKI, disk, and
      # the proofs in proof.txt. Keys are throwaways made in the store; a release signs with the
      # deployment's keys (image/default.nix). image-smoke-<step> exposes each step on its own.
      image-smoke = imageSmoke.smoke;
      image-smoke-erofs = imageSmoke.erofs;
      image-smoke-verity = imageSmoke.verity;
      image-smoke-initrd = imageSmoke.initrd;
      image-smoke-uki = imageSmoke.uki;
      image-smoke-disk = imageSmoke.disk;
      image-smoke-loader = imageSmoke.loader;

      image-smoke-test =
        (imageChain {
          config = testConfig "20261031.1";
          sbKeys = throwawayKeys;
        }).smoke;

      # The next release of the test image, signed with a new db key: the loader, the UKI and
      # the verity root hash take rotatedKeys; the PCR policy key stays, so a credential sealed
      # by 20261031.1 still unseals. scripts/boot-test --next <this> --rotate installs it and
      # rotates the firmware's db (docs/design/bootloader.md).
      image-smoke-test-rotated =
        (imageChain {
          config = testConfig "20261031.2";
          sbKeys = rotatedKeys;
          pcrKeys = throwawayKeys;
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
    { platform }:
    import ./checks.nix {
      inherit sources self;
      double = platform.name;
    };

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

  # Generated SUMMARY.md content.
  docs-summary = docsFromSchema.summary;

  # Module paths discovered from modules/ directory.
  docs-module-paths = docsFromSchema.modulePaths;

  # TOML configuration loader. Returns { loadConfig; loadAndApply; validPaths; withPkgs; }.
  #   (import ./default.nix).configLib.loadConfig ./config.toml
  #   ((import ./default.nix).configLib.withPkgs set).loadAndApply ./config.toml
  configLib = import ../lib/config.nix {
    tree = tree { };
    modules = tree;
  };

  # The platforms table (repkgs nix/platforms.nix), for callers that need all target names.
  # Not per-system: the same table on every build host.
  platforms = import "${sources.repkgs}/nix/platforms.nix";

  # lib: Nix library functions for building Golconda systems.
  #   (import ./default.nix).lib.mkSystem { config = ./server.toml; }
  lib = { inherit mkSystem; };
}
