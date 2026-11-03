# A downstream fixture package (tests/eval/components.nix): repkgs' xxhash spec under the name
# openssh, at a version that marks it as the fixture. Evaluated, never built.
{ package }:
package {
  name = "openssh";
  uses = [ "cmake" ];
  cmake.root = "cmake_unofficial";
}
