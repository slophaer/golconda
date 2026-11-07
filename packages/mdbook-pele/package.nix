# mdbook-pele: the book's mdbook preprocessor (docs/book.toml) that renders ```mermaid blocks to
# inline SVG with pele at build time (mdbook-pele.mjs, ours), so the book ships no diagram
# JavaScript. pele is the npm package of the source; it has no dependencies of its own. A
# development tool, not part of an image.
{ package, pkgs }:
let
  script = builtins.path {
    path = ./mdbook-pele.mjs;
    name = "mdbook-pele.mjs";
  };
in
package {
  name = "mdbook-pele";
  # bin/mdbook-pele runs node: the interpreter, found via the launcher
  dependencies = [ pkgs.nodejs ];
  phases = [
    {
      name = "install";
      run = ''
        let lib = $"($c.out)/lib/mdbook-pele"
        mkdir $lib $"($c.out)/bin"
        ^cp -r dist package.json LICENSE $lib
        ^cp ${script} $"($lib)/mdbook-pele.mjs"
        [
          "#!/bin/sh"
          "# mdbook runs this with its preprocessor arguments; pele's renderer is beside the script"
          'lib=$(dirname "$(realpath "$0")")/../lib/mdbook-pele'
          'exec node "$lib/mdbook-pele.mjs" "$lib/dist/pele.js" "$@"'
        ] | str join "\n" | save $"($c.out)/bin/mdbook-pele"
        ^chmod +x $"($c.out)/bin/mdbook-pele"
      '';
    }
  ];
  bin = [ "mdbook-pele" ];
  # mdbook-pele takes the preprocessor protocol, not --version
  tests.version = false;
}
