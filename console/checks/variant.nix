# A package that is the console's (console/package.nix: its source, crates, patches, tools, env
# and repkgs toolchain) with other phases: for checks of the console's code (checks/*). repkgs
# passes a package the arguments its function names, so the result names them and passes them on.
{
  name,
  phases,
  bin ? [ ],
}:
{
  package,
  pkgs,
  buildPkgs,
}:
import ../package.nix {
  inherit pkgs buildPkgs;
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
