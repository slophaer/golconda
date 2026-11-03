# A downstream fixture package (tests/eval/components.nix): repkgs' xxhash spec under the name
# cpython, at a version that marks it as the fixture. Evaluated, never built.
{ package }:
package {
  name = "cpython";
  uses = [ "cmake" ];
  cmake.root = "cmake_unofficial";
}
