# A downstream fixture package (tests/eval/components.nix): repkgs' xxhash spec under the name
# hello, at a version that marks it as the fixture. Evaluated, never built.
{ package }:
package {
  name = "hello";
  uses = [ "cmake" ];
  cmake.root = "cmake_unofficial";
}
