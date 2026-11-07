# wcwidth (pypi: wcwidth): for mdformat, the Markdown formatter (treefmt's markdown, packages/mdformat).
{
  package,
  buildPkgs,
}:
package {
  name = "python-wcwidth";
  uses = [ "python" ];
  buildDependencies = [ buildPkgs.python-setuptools ];
  python.module = "wcwidth";
}
