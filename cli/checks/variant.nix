# A package that is the command line's (cli/package.nix: its source, crates, patches, tools, env
# and repkgs toolchain) with other phases: for checks of the command line's code (checks/*). repkgs
# passes a package the arguments its function names, so the result names them and passes them on.
{
  name,
  phases,
  bin ? [ ],
}:
{
  package,
  buildPkgs,
}:
import ../package.nix {
  inherit buildPkgs;
  package =
    spec:
    package (
      spec
      // {
        inherit name phases bin;
        tests.version = false;
      }
    );
}
