# A downstream fixture package (tests/eval/image-config.nix): repkgs' xxhash spec under the
# name tzdata, at a version that marks it as the fixture. Evaluated, never built.
{ variant, pkgs }:
variant pkgs.xxhash { }
