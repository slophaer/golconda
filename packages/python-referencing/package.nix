# referencing: JSON references ($ref) across schemas; for python's jsonschema (checks.schema-metaschema, packages/python-jsonschema)
{
  package,
  sources,
  pkgs,
  buildPkgs,
}:
package {
  name = "python-referencing";
  uses = [ "python" ];
  python.backend = "hatchling";
  python.module = "referencing";
  buildDependencies = [
    buildPkgs.python-hatchling
    buildPkgs.python-hatch-vcs
  ];
  dependencies = [
    pkgs.python-attrs
    pkgs.rpds-py
  ];
  # hatch-vcs takes the version from git, which a PyPI source has not
  env.SETUPTOOLS_SCM_PRETEND_VERSION = sources.version;
}
