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
      ...
    }:
    let
      imageSmoke =
        let
          # the base system of examples/server.toml, as lib.mkSystem makes it
          sys = mkSystem {
            inherit system;
            platform = system;
            config = ../examples/server.toml;
          };
          imageId = sys.name;
          inherit (sys)
            version
            usrTree
            platform
            pkgs
            ;
          args = {
            inherit
              imageId
              version
              pkgs
              platform
              ;
            buildSystem = system;
          };
          initrdTree = imageLib.initrdTree args;
          keys = imageLib.throwawayKeys {
            inherit pkgs;
            buildSystem = system;
          };
        in
        rec {
          erofs = imageLib.erofs (args // { inherit usrTree; });
          verity = imageLib.verity (
            args
            // {
              inherit erofs;
              key = "${keys}/verity/verity.key";
              cert = "${keys}/verity/verity.crt";
            }
          );
          initrd = imageLib.initrd (args // { usrTree = initrdTree; });
          uki = imageLib.uki (
            args
            // {
              inherit initrd verity usrTree;
              sbKey = "${keys}/secureboot/db.key";
              sbCert = "${keys}/secureboot/db.crt";
              pcrKey = "${keys}/pcr/pcr.key";
              pcrPublicKey = "${keys}/pcr/pcr.pub";
              # Stand-ins, both for the smoke only (image/uki.nix stays the decided cmdline):
              # LD_LIBRARY_PATH until the fork's RUNPATH reaches what systemd dlopens (libmount
              # in PID 1, libcryptsetup for /usr, the journal's compression): the store
              # directories behind /base's dlopen links, as the kernel hands them to PID 1
              # (services get them from /base's system.conf.d). rw until gpt-auto-generator
              # succeeds in the host (it exits 1 there today) and writes the remount-rw drop-in
              # itself; without it the root partition stays read-only and sysusers, vars and
              # state directories fail. To watch a boot add systemd.log_level=debug
              # systemd.log_target=console systemd.journald.forward_to_console=1.
              cmdlineExtra = "LD_LIBRARY_PATH={dlopenPath} rw";
            }
          );
          disk = imageLib.disk (args // { inherit erofs verity uki; });
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

      # Boot test image: examples/test-boot/config.toml with the test CA for SSH login.
      # The test CA private key is in examples/test-boot/ca; scripts/boot-test uses it.
      image-smoke-test =
        let
          sys = mkSystem {
            inherit system;
            platform = system;
            config = ../examples/test-boot/config.toml;
          };
          testKeys = imageLib.throwawayKeys {
            inherit pkgs;
            buildSystem = system;
          };
          testArgs = {
            imageId = sys.name;
            inherit (sys) version platform pkgs;
            buildSystem = system;
          };
          testInitrdTree = imageLib.initrdTree testArgs;
          testErofs = imageLib.erofs (testArgs // { inherit (sys) usrTree; });
          testVerity = imageLib.verity (
            testArgs
            // {
              erofs = testErofs;
              key = "${testKeys}/verity/verity.key";
              cert = "${testKeys}/verity/verity.crt";
            }
          );
          testInitrd = imageLib.initrd (testArgs // { usrTree = testInitrdTree; }); # not sys.usrTree
          testUki = imageLib.uki (
            testArgs
            // {
              initrd = testInitrd;
              verity = testVerity;
              inherit (sys) usrTree;
              sbKey = "${testKeys}/secureboot/db.key";
              sbCert = "${testKeys}/secureboot/db.crt";
              pcrKey = "${testKeys}/pcr/pcr.key";
              pcrPublicKey = "${testKeys}/pcr/pcr.pub";
              cmdlineExtra = "LD_LIBRARY_PATH={dlopenPath} rw";
            }
          );
          testDisk = imageLib.disk (
            testArgs
            // {
              erofs = testErofs;
              verity = testVerity;
              uki = testUki;
            }
          );
        in
        imageLib.smoke (
          testArgs
          // {
            erofs = testErofs;
            verity = testVerity;
            initrd = testInitrd;
            uki = testUki;
            disk = testDisk;
            keys = testKeys;
          }
        );

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
