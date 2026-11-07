# mdit_py_plugins (pypi: mdit-py-plugins): for mdformat, the Markdown formatter (treefmt's markdown, packages/mdformat).
{
  package,
  pkgs,
}:
package {
  name = "python-mdit-py-plugins";
  uses = [ "python" ];
  python.backend = "flit_core";
  python.module = "mdit_py_plugins";
  dependencies = [
    pkgs.python-markdown-it-py
  ];
}
