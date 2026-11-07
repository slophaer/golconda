# mdformat_gfm (pypi: mdformat-gfm): GitHub-flavoured Markdown (tables, task lists) for mdformat,
# the Markdown formatter (treefmt's markdown, packages/mdformat). It does not depend on mdformat,
# although it imports it: mdformat depends on it instead, which is how mdformat finds the plugin.
{
  package,
  pkgs,
}:
package {
  name = "python-mdformat-gfm";
  uses = [ "python" ];
  python.backend = "flit_core";
  python.module = "mdformat_gfm";
  # importing it imports mdformat, which depends on it to find it as a plugin (packages/mdformat):
  # mdformat's own import test and checks.treefmt exercise it
  tests.run = false;
  dependencies = [
    pkgs.python-markdown-it-py
    pkgs.python-mdit-py-plugins
    pkgs.python-wcwidth
  ];
}
