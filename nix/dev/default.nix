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

  # ast-grep with the rules in lints/: Rust and Nix are built in, nu comes from the
  # tree-sitter grammar nushell maintains. lints/tests/ holds a case for each rule.
  lints = builtins.path {
    path = ../../lints;
    name = "golconda-lints";
  };
  sgconfig = pkgs.writeText "sgconfig.yml" (
    builtins.toJSON {
      ruleDirs = map (d: "${lints}/${d}") [
        "rust"
        "nu"
        "nix"
      ];
      testConfigs = [ { testDir = "${lints}/tests"; } ];
      customLanguages.nu = {
        libraryPath = "${pkgs.tree-sitter-grammars.tree-sitter-nu}/parser";
        extensions = [ "nu" ];
        expandoChar = "_";
      };
    }
  );
  # the nu grammar is a native library: allow it, it is the pinned one above
  ast-grep = pkgs.writeShellScriptBin "golconda-ast-grep" ''
    exec ${pkgs.ast-grep}/bin/ast-grep "$1" --config=${sgconfig} --custom-languages=allow "''${@:2}"
  '';

  # nu's own parser and type checker over each file: a misspelt command, a wrong
  # type, a `use` that does not resolve. The include path is what the builds pass:
  # the image and /usr tree modules, repkgs' builder and its test library.
  # cell-path-types: `$rec.field` takes the field's declared type instead of `any`.
  nu-typecheck = pkgs.writeShellScript "nu-typecheck" ''
    status=0
    for f in "$@"; do
      out=$(${pkgs.nushell}/bin/nu --no-config-file \
        --include-path "$PWD/lib/image:$PWD/lib/usr-tree:${sources.repkgs}/builder:${sources.repkgs}/tests/builder/lib" \
        "--experimental-options=[cell-path-types]" --ide-check 50 "$f" \
        | ${pkgs.jq}/bin/jq -r 'select(.type == "diagnostic" and .severity == "Error") | "\(.span.start): \(.message)"')
      if [ -n "$out" ]; then printf '%s:\n%s\n' "$f" "$out" >&2; status=1; fi
    done
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
        # console/: the edition is the workspace's (console/Cargo.toml)
        rust = {
          command = "${pkgs.rustfmt}/bin/rustfmt";
          options = [
            "--edition"
            "2024"
          ];
          includes = [ "*.rs" ];
        };
        # check only: the rules in lints/ (rust, nu, nix)
        ast-grep = {
          command = "${ast-grep}/bin/golconda-ast-grep";
          options = [
            "scan"
            "--report-style=short"
          ];
          includes = [
            "*.rs"
            "*.nu"
            "*.nix"
          ];
        };
        # check only, nu has no stable formatter
        nu-typecheck = {
          command = "${nu-typecheck}";
          includes = [ "*.nu" ];
        };
        # check only; scripts/check-doc-links is Python
        shellcheck = {
          command = "${pkgs.shellcheck}/bin/shellcheck";
          includes = [
            "*.sh"
            "scripts/boot-test"
            "scripts/docs"
            "scripts/lint"
            "scripts/make-keys"
            "scripts/provision-esp"
          ];
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
    ast-grep
    ;

  shell = pkgs.mkShellNoCC {
    packages = [
      treefmt
      ast-grep
      mdbook
      mdbook-pele
      iets
      pkgs.npins
    ];
    shellHook = ''
      echo "golconda dev shell: treefmt | golconda-ast-grep scan|test | iets lint: ./scripts/lint | docs: scripts/docs serve"
    '';
  };
}
