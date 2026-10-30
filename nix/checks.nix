# Checks that run inside the sandbox. The iets lint needs the pins fetched and
# runs in CI as scripts/lint (iets.toml holds its strict levels).
{
  sources,
  self,
  double,
}:
let
  dev = import ./dev { inherit sources; } double;
  pkgs = import sources.nixpkgs-dev-only { system = double; };
  src = builtins.path {
    path = self;
    name = "golconda-src";
    filter = p: _: baseNameOf p != ".git" && !(pkgs.lib.hasPrefix "result" (baseNameOf p));
  };
in
{
  # formatting and Nix lints, as treefmt sees them
  treefmt = pkgs.runCommand "check-treefmt" { nativeBuildInputs = [ dev.treefmt ]; } ''
    cp -r ${src} src && chmod -R u+w src && cd src
    treefmt --ci --no-cache --tree-root .
    touch $out
  '';

  # the docs build; a broken include or mermaid block fails here
  docs =
    pkgs.runCommand "check-docs"
      {
        nativeBuildInputs = [
          dev.mdbook
          dev.mdbook-mermaid
        ];
      }
      ''
        cp -r ${src}/docs docs && chmod -R u+w docs && cd docs
        mdbook-mermaid install . # the two js files are generated, not committed
        mdbook build -d $out
      '';

  # nixpkgs is dev tooling only: the dev pin is referenced nowhere but nix/dev and nix/checks.nix
  boundary = pkgs.runCommand "check-boundary" { } ''
    cd ${src}
    if grep -rn --include='*.nix' 'nixpkgs-dev-only\|<nixpkgs>' . | grep -v '^./nix/dev/' | grep -v '^./nix/checks.nix' | grep -v '^./npins/'; then
      echo "nixpkgs referenced outside nix/dev (see docs/design/principles.md)" >&2
      exit 1
    fi
    touch $out
  '';
}
