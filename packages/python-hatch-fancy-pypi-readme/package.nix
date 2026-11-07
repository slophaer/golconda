# hatch-fancy-pypi-readme: a hatchling plugin that builds a package's readme from fragments; for python's jsonschema (checks.schema-metaschema, packages/python-jsonschema)
{
  package,
  buildPkgs,
}:
package {
  name = "python-hatch-fancy-pypi-readme";
  uses = [ "python" ];
  python.backend = "hatchling";
  python.module = "hatch_fancy_pypi_readme";
  buildDependencies = [
    buildPkgs.python-hatchling
  ];
}
