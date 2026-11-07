# markdown_it (pypi: markdown-it-py): for mdformat, the Markdown formatter (treefmt's markdown, packages/mdformat).
{
  package,
  pkgs,
}:
package {
  name = "python-markdown-it-py";
  uses = [ "python" ];
  python.backend = "flit_core";
  python.module = "markdown_it";
  dependencies = [
    pkgs.python-mdurl
  ];
}
