# The tree-sitter grammar for nu, as one shared library at $out/parser (the layout nixpkgs'
# tree-sitter grammars have): ast-grep loads it for the nu rules in lints/ (nix/dev, sgconfig's
# customLanguages). A development tool, not part of an image.
{ package }:
package {
  name = "tree-sitter-nu";
  phases = [
    {
      name = "build";
      run = ''
        mkdir $c.out
        x cc -shared -fPIC -O2 -I src src/parser.c src/scanner.c -o $"($c.out)/parser"
      '';
    }
  ];
  bin = [ ];
  tests.version = false;
}
