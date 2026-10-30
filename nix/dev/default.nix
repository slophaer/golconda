# Developer tooling only: formatter, linters, docs build, dev shell.
#
# This directory is the ONLY place allowed to import nixpkgs (pin
# `nixpkgs-dev-only`). Nothing it builds ships in an image or is a dependency
# of a package; checks/boundary enforces that. It exists because repkgs does not
# package these tools yet; each one moves to packages/ when it does.
{ sources }:
double:
let
  pkgs = import sources.nixpkgs-dev-only { system = double; };

  statix-each = pkgs.writeShellScript "statix-each" ''
    status=0
    for f in "$@"; do ${pkgs.statix}/bin/statix check -c ${
      builtins.path {
        path = ../../statix.toml;
        name = "statix.toml";
      }
    } "$f" || status=1; done
    exit $status
  '';

  treefmt = pkgs.treefmt.withConfig {
    settings = {
      global.excludes = [
        "npins/*"
        "result*"
        "LICENSE"
      ];
      formatter = {
        nix = {
          command = "${pkgs.nixfmt}/bin/nixfmt";
          includes = [ "*.nix" ];
        };
        nix-statix = {
          command = "${statix-each}";
          includes = [ "*.nix" ];
        };
        nix-deadnix = {
          command = "${pkgs.deadnix}/bin/deadnix";
          options = [
            "--fail"
            "--edit"
          ];
          includes = [ "*.nix" ];
        };
        markdown = {
          command = "${pkgs.mdformat.withPlugins (p: [ p.mdformat-gfm ])}/bin/mdformat";
          options = [ "--wrap=100" ];
          includes = [ "*.md" ];
        };
        toml = {
          command = "${pkgs.taplo}/bin/taplo";
          options = [ "format" ];
          includes = [ "*.toml" ];
        };
      };
    };
  };

  inherit (pkgs) mdbook;

  # mermaid blocks become inline SVG at build time with Pele (pin `pele`)
  mdbook-pele = pkgs.writeShellScriptBin "mdbook-pele" ''
    exec ${pkgs.nodejs-slim}/bin/node ${
      builtins.path {
        path = ./mdbook-pele.mjs;
        name = "mdbook-pele.mjs";
      }
    } ${sources.pele}/dist/pele.js "$@"
  '';

  # iets from its own flake (crane build); the system Nix is its fallback only
  # in classic mode, which the dev shell does not use.
  iets =
    (import "${sources.iets}/nix/flake-compat.nix" {
      src = sources.iets;
      system = double;
    }).defaultNix.packages.${double}.default;
in
{
  inherit
    treefmt
    mdbook
    mdbook-pele
    iets
    ;

  shell = pkgs.mkShellNoCC {
    packages = [
      treefmt
      mdbook
      mdbook-pele
      iets
      pkgs.npins
    ];
    shellHook = ''
      echo "golconda dev shell: treefmt | iets lint: ./scripts/lint | docs: mdbook serve docs"
    '';
  };
}
