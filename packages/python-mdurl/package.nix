# mdurl (pypi: mdurl): for mdformat, the Markdown formatter (treefmt's markdown, packages/mdformat).
{
  package,
}:
package {
  name = "python-mdurl";
  uses = [ "python" ];
  python.backend = "flit_core";
  python.module = "mdurl";
}
