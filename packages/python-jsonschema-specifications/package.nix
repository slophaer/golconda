# jsonschema-specifications: the JSON Schema metaschemas, as data; for python's jsonschema (checks.schema-metaschema, packages/python-jsonschema)
{
  package,
  sources,
  pkgs,
  buildPkgs,
}:
package {
  name = "python-jsonschema-specifications";
  uses = [ "python" ];
  python.backend = "hatchling";
  python.module = "jsonschema_specifications";
  buildDependencies = [
    buildPkgs.python-hatchling
    buildPkgs.python-hatch-vcs
  ];
  dependencies = [
    pkgs.python-referencing
  ];
  # hatch-vcs takes the version from git, which a PyPI source has not
  env.SETUPTOOLS_SCM_PRETEND_VERSION = sources.version;
}
