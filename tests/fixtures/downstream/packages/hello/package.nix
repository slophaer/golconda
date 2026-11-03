# A downstream fixture package (tests/eval/components.nix): repkgs' xxhash spec under the name
# hello, with a different display name and a version that mark it as the fixture.
# Evaluated, never built.
{ package, pkgs }:
package {
  name = "hello-binary";
  dependencies = [ pkgs.ripgrep ];
  uses = [ "cmake" ];
  cmake.root = "cmake_unofficial";
}
