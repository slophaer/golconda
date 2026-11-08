# attrs: classes without boilerplate; for python's jsonschema (checks.schema-parity, packages/python-jsonschema)
{
  package,
  sources,
  buildPkgs,
}:
package {
  name = "python-attrs";
  uses = [ "python" ];
  python.backend = "hatchling";
  python.module = "attrs";
  buildDependencies = [
    buildPkgs.python-hatchling
    buildPkgs.python-hatch-vcs
    buildPkgs.python-hatch-fancy-pypi-readme
  ];
  # hatch-vcs takes the version from git, which a PyPI source has not
  env.SETUPTOOLS_SCM_PRETEND_VERSION = sources.version;
}
