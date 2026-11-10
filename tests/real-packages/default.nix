# The checks that need the real package set (repkgs' set, Golconda's packages as derivations, the
# SBOM generator, the image chain). checks.real-packages evaluates this file (nix/checks.nix), so
# scripts/lint runs it; tests/eval keeps everything that reads packages as data.
# It is `true` or throws with the failing check's name. No derivation is built.
#
# Each file is one area: a function of the harness below that returns a list of checks.
{
  sources ? import ../../pins,
  platform ? "x86_64-linux",
}:
let
  inherit (builtins) stringLength substring;
  harness = {
    inherit sources platform;
    check = name: cond: if cond then true else throw "golconda real-package tests: ${name} failed";
    f = import ../../default.nix;
    inherit
      (import ../../nix/packages.nix {
        inherit sources platform;
        system = platform;
      })
      pkgs
      ;
    hasPrefix = p: s: substring 0 (stringLength p) s == p;
    hasInfix =
      needle: hay:
      let
        n = stringLength needle;
        h = stringLength hay;
      in
      n <= h && builtins.any (i: substring i n hay == needle) (builtins.genList (i: i) (h - n + 1));
  };
  areas = map (area: import area harness) [
    ./packages.nix
    ./image-config.nix
    ./sbom.nix
  ];
in
assert builtins.all (t: t) (builtins.concatLists areas);
true
