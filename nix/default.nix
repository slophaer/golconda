# The flake-incompat expression. Each per-system field is a function of
# { pkgs, platform, set, system } (default.nix argsFun); the rest is plain.
{ sources, self }:
let
  dev = import ./dev { inherit sources; };
  adios = import sources.adios;
  # The adios module tree (modules/); `tree { options = {...}; }` evaluates it.
  # Nothing per-system: a configuration passes its repkgs set as options."/pkgs".set.
  tree = import ../modules { inherit (adios) adios; };
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
  usrTreeLib = import ../lib/usr-tree.nix { };
in
{
  packages =
    {
      pkgs,
      platform,
      system,
      set,
      ...
    }:
    {
      # the patched Nix daemon repkgs needs (CA + dynamic derivations); builders run it
      inherit (pkgs) nix;

      # Smoke test for the /usr tree builder: a minimal system with jq
      usr-tree-smoke =
        let
          # Create a minimal composer output
          composed = tree {
            options = {
              "/pkgs".set = set;
              "/system" = {
                name = "smoke";
                version = "20261031.1";
                fragments = [
                  {
                    packages = [ pkgs.jq ];
                    # jq has bin = [ "jq" ] in repkgs
                  }
                ];
              };
            };
          };
          sys = composed.modules.system { };
        in
        usrTreeLib.usrTree {
          composerOutput = sys;
          inherit platform;
          version = "20261031.1";
        };

      # Smoke test for /base alone: no extra fragments, just the base packages.
      # Verifies: no absolute symlinks, no GNU coreutils, base packages only.
      usr-tree-base-smoke =
        let
          composed = tree {
            options = {
              "/pkgs".set = set;
              "/system" = {
                name = "base-smoke";
                version = "20261031.1";
                fragments = [ ]; # no extra packages
              };
            };
          };
          sys = composed.modules.system { };
        in
        usrTreeLib.usrTree {
          composerOutput = sys;
          inherit platform;
          version = "20261031.1";
        };

      # Cross-compiled usr-tree for aarch64: proves the platform argument flows through.
      # Built on x86_64, runs on aarch64. The jq binary in the output is an aarch64 ELF.
      # Visible only in packages.x86_64-linux (cross builds from x86_64 to aarch64).
    }
    // (
      if system == "x86_64-linux" then
        let
          # Build for aarch64-linux from this x86_64-linux host
          crossSet = import ./packages.nix {
            inherit sources;
            inherit system;
            platform = "aarch64-linux";
          };
          crossTree = import ../modules { inherit (adios) adios; };
          composed = crossTree {
            options = {
              "/pkgs".set = crossSet;
              "/system" = {
                name = "smoke-aarch64";
                version = "20261031.1";
                fragments = [
                  {
                    packages = [ crossSet.pkgs.jq ];
                  }
                ];
              };
            };
          };
          sys = composed.modules.system { };
        in
        {
          usr-tree-smoke-aarch64 = usrTreeLib.usrTree {
            composerOutput = sys;
            inherit (crossSet) platform;
            version = "20261031.1";
            # Build on this host (x86_64), output for the target (aarch64)
            buildSystem = system;
          };
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
}
