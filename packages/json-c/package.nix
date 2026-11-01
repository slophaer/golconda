# json-c: JSON library for C
{ package }:
package {
  name = "json-c";
  uses = [ "cmake" ];
  cmake.defs = {
    BUILD_STATIC_LIBS = false;
    DISABLE_WERROR = true; # strict warnings fail with clang
    DISABLE_EXTRA_LIBS = true;
    DISABLE_BSYMBOLIC = true;
  };
  # Tests pass but take a while
  tests.run = true;
  bin = [ ]; # library only
}
