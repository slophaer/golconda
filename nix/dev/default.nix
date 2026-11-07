# Developer tooling only: formatter, linters, docs build, dev shell.
#
# This directory is the ONLY place allowed to import nixpkgs (pin
# `nixpkgs-dev-only`). Nothing it builds ships in an image or is a dependency
# of a package; checks/boundary enforces that. It exists because repkgs does not
# package these tools yet; each one moves to packages/ when it does. The ones
# that moved come from the repkgs set (`rp`), and whatever names them is built
# with nix/run.nix: a nixpkgs derivation cannot depend on a content-addressed one
# on this daemon.
{ sources }:
double: set:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    isList
    toJSON
    ;
  pkgs = import sources.nixpkgs-dev-only { system = double; };
  rp = set.pkgs;
  run = import ../run.nix set;
  seed = set.bootstrap.seed;

  # writeScript NAME TEXT: $out/bin/NAME, executable, run by the seed's sh
  writeScript =
    name: text:
    run name [ ] ''
      mkdir -p $out/bin
      cat > $out/bin/${name} <<'GOLCONDA_SCRIPT_EOF'
      #!${seed}/bin/sh
      ${text}
      GOLCONDA_SCRIPT_EOF
      chmod +x $out/bin/${name}
    '';

  # TOML for treefmt's config: tables of strings and lists of strings (JSON's quoting is TOML's
  # for these)
  toTOML =
    tables:
    concatStringsSep "\n" (
      map (
        t:
        "[${t}]\n"
        + concatStringsSep "" (
          map (
            k:
            let
              v = tables.${t}.${k};
            in
            "${k} = ${if isList v then toJSON v else toJSON v}\n"
          ) (attrNames tables.${t})
        )
      ) (attrNames tables)
    );

  statix-each = writeScript "statix-each" ''
    status=0
    for f in "$@"; do ${rp.statix}/bin/statix check -c ${
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
  sgconfig = run "sgconfig.yml" [ ] ''
    cat > $out <<'GOLCONDA_SGCONFIG_EOF'
    ${toJSON {
      ruleDirs = map (d: "${lints}/${d}") [
        "rust"
        "nu"
        "nix"
      ];
      testConfigs = [ { testDir = "${lints}/tests"; } ];
      customLanguages.nu = {
        libraryPath = "${rp.tree-sitter-nu}/parser";
        extensions = [ "nu" ];
        expandoChar = "_";
      };
    }}
    GOLCONDA_SGCONFIG_EOF
  '';
  # the nu grammar is a native library: allow it, it is the pinned one above
  # ($1: the subcommand; the rest after the config)
  ast-grep = writeScript "golconda-ast-grep" ''
    sub=$1
    shift
    exec ${rp.ast-grep}/bin/ast-grep "$sub" --config=${sgconfig} --custom-languages=allow "$@"
  '';

  # nu's own parser and type checker over each file: a misspelt command, a wrong
  # type, a `use` that does not resolve. The include path is what the builds pass:
  # the image and /usr tree modules, repkgs' builder and its test library.
  # cell-path-types: `$rec.field` takes the field's declared type instead of `any`.
  # repkgs' nushell, the one its builders and ours run.
  nu-typecheck = writeScript "nu-typecheck" ''
    status=0
    for f in "$@"; do
      out=$(${rp.nushell}/bin/nu --no-config-file \
        --include-path "$PWD/lib/image:$PWD/lib/usr-tree:${sources.repkgs}/builder:${sources.repkgs}/tests/builder/lib" \
        "--experimental-options=[cell-path-types]" --ide-check 50 "$f" \
        | ${rp.jq}/bin/jq -r 'select(.type == "diagnostic" and .severity == "Error") | "\(.span.start): \(.message)"')
      if [ -n "$out" ]; then printf '%s:\n%s\n' "$f" "$out" >&2; status=1; fi
    done
    exit $status
  '';

  # treefmt with its config: a wrapper adds --config-file, as nixpkgs' treefmt.withConfig did
  treefmtConfig = run "treefmt.toml" [ ] ''
    cat > $out <<'GOLCONDA_TOML_EOF'
    ${toTOML {
      global.excludes = [
        "npins/*"
        "result*"
        "LICENSE"
      ];
      "formatter.nix" = {
        command = "${rp.nixfmt-rs}/bin/nixfmt";
        includes = [ "*.nix" ];
      };
      "formatter.nix-statix" = {
        command = "${statix-each}/bin/statix-each";
        includes = [ "*.nix" ];
      };
      "formatter.nix-deadnix" = {
        command = "${rp.deadnix}/bin/deadnix";
        options = [
          "--fail"
          "--edit"
        ];
        includes = [ "*.nix" ];
      };
      "formatter.markdown" = {
        command = "${rp.mdformat}/bin/mdformat";
        options = [ "--wrap=100" ];
        includes = [ "*.md" ];
      };
      "formatter.toml" = {
        command = "${rp.taplo}/bin/taplo";
        options = [ "format" ];
        includes = [ "*.toml" ];
      };
      # console/: the edition is the workspace's (console/Cargo.toml)
      "formatter.rust" = {
        command = "${rp.rust}/bin/rustfmt";
        options = [
          "--edition"
          "2024"
        ];
        includes = [ "*.rs" ];
      };
      # check only: the rules in lints/ (rust, nu, nix)
      "formatter.ast-grep" = {
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
      "formatter.nu-typecheck" = {
        command = "${nu-typecheck}/bin/nu-typecheck";
        includes = [ "*.nu" ];
      };
      # check only; scripts/check-doc-links is Python
      "formatter.shellcheck" = {
        command = "${rp.shellcheck}/bin/shellcheck";
        includes = [
          "*.sh"
          "scripts/boot-test"
          "scripts/docs"
          "scripts/lint"
          "scripts/make-keys"
          "scripts/tool"
          "scripts/provision-esp"
        ];
      };
    }}
    GOLCONDA_TOML_EOF
  '';
  treefmt = writeScript "treefmt" ''
    exec ${rp.treefmt}/bin/treefmt --config-file ${treefmtConfig} "$@"
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
    iets
    ast-grep
    ;

  # nixpkgs' mkShell cannot take a content-addressed input on this daemon, so treefmt,
  # golconda-ast-grep, mdbook and mdbook-pele (ours now) are not in it: `nix fmt` runs the formatter output,
  # which runs the lint rules too, checks.lint-rules tests them, and scripts/docs and scripts/tool
  # find our packages through scripts/tools.sh
  shell = pkgs.mkShellNoCC {
    packages = [
      iets
      pkgs.npins
    ];
    shellHook = ''
      echo "golconda dev shell: nix fmt | iets lint: ./scripts/lint | docs: scripts/docs serve"
    '';
  };
}
