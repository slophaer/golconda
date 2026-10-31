# The flake-incompat expression. Each per-system field is a function of
# { pkgs, platform, set } (default.nix argsFun); the rest is plain.
{ sources, self }:
let
  dev = import ./dev { inherit sources; };
  adios = import sources.adios;
  docsFromSchema =
    let
      schemaLib = import ../lib/schema.nix { };
      tree = import ../modules { inherit (adios) adios; };
    in
    (import ../lib/module-docs.nix { }).toMarkdown (schemaLib.toJsonSchema (tree { }));
in
{
  packages =
    { pkgs, set }:
    {
      # the patched Nix daemon repkgs needs (CA + dynamic derivations); builders run it
      inherit (pkgs) nix;

      # Smoke test for /wrap: jq with --version prepended to its arguments
      wrap-smoke = set.wrap {
        package = pkgs.jq;
        argv = [ "--version" ];
      };
    };

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
  modules = import ../modules { inherit (adios) adios; };

  # JSON Schema 2020-12 export of the module tree. Not per-system: the schema
  # depends only on the module definitions, not on any packages.
  #   iets eval --json -E '(import ./default.nix).schema'
  schema =
    let
      schemaLib = import ../lib/schema.nix { };
      tree = import ../modules { inherit (adios) adios; };
    in
    schemaLib.toJsonSchema (tree { });

  # Markdown reference pages generated from the schema (lib/module-docs.nix).
  #   iets eval --raw -E '(import ./default.nix).docs-modules."/system"'
  docs-modules = docsFromSchema.pages;

  # The same pages by file name (services-sshd.md, index.md); scripts/docs writes these.
  docs-pages = docsFromSchema.files;

  # TOML configuration loader. Returns { loadConfig; loadAndApply; validPaths; }.
  #   (import ./default.nix).configLib.loadConfig ./config.toml
  configLib =
    let
      mods = import ../modules { inherit (adios) adios; };
    in
    import ../lib/config.nix {
      tree = mods { };
      modules = mods;
    };
}
