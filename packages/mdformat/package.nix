# mdformat: the Markdown formatter (treefmt's markdown, --wrap=100), with the GFM plugin. A
# development tool, not part of an image. mdformat finds plugins by entry point on its own
# sys.path, which its script builds from its dependencies, so the plugin is a dependency here.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "mdformat";
  uses = [ "python" ];
  buildDependencies = [ buildPkgs.python-setuptools ];
  python.module = "mdformat";
  dependencies = [
    # bin/mdformat is `#!.../python3`: the interpreter, found via the launcher
    pkgs.cpython
    pkgs.python-markdown-it-py
    pkgs.python-mdformat-gfm
  ];
  bin = [ "mdformat" ];
}
