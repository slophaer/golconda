# A downstream fixture package (tests/eval/components.nix): repkgs' xxhash spec under the name
# ripgrep, at a version that marks it as the fixture. Evaluated, never built.
{ variant, pkgs }:
variant pkgs.xxhash { }
