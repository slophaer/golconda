# jsonschema: a whole JSON Schema implementation. A development tool, not part of an image: checks.schema-parity checks Golconda's schema and its fixtures with it
{
  package,
  sources,
  pkgs,
  buildPkgs,
}:
package {
  name = "python-jsonschema";
  uses = [ "python" ];
  python.backend = "hatchling";
  python.module = "jsonschema";
  buildDependencies = [
    buildPkgs.python-hatchling
    buildPkgs.python-hatch-vcs
    buildPkgs.python-hatch-fancy-pypi-readme
  ];
  dependencies = [
    pkgs.python-attrs
    pkgs.python-jsonschema-specifications
    pkgs.python-referencing
    pkgs.rpds-py
  ];
  # hatch-vcs takes the version from git, which a PyPI source has not
  env.SETUPTOOLS_SCM_PRETEND_VERSION = sources.version;
}
