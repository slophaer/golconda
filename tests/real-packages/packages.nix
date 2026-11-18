# Checks that need the real package set: the outputs and the packages' build specs as repkgs
# resolves them. tests/eval reads packages as data only (tests/fixtures/repkgs).
# A function of ./default.nix's harness; it returns a list of checks.
{
  check,
  f,
  pkgs,
  sources,
  ...
}:
let
  inherit (builtins) attrNames;
in
[
  (check "outputs: x86_64 keeps the native kernel and the test image" (
    f.packages.x86_64-linux ? kernel && f.packages.x86_64-linux ? image-smoke-test
  ))
  (check "kernel: the package owns the base; env.merge adds the extra config and fragment only" (
    let
      own = pkgs.linux-kernel.args.env;
      final = pkgs.linux-kernel.drvAttrs.spec.env;
    in
    attrNames final == attrNames own
    && final.GOLCONDA_KERNEL_CONFIG == own.GOLCONDA_KERNEL_CONFIG
    && final.GOLCONDA_KERNEL_EXTRA_CONFIG == "{}"
    && final.GOLCONDA_KERNEL_FRAGMENTS != own.GOLCONDA_KERNEL_FRAGMENTS
  ))
  (check "kernel: GOLCONDA_KERNEL_MAKE survives env.merge" (
    let
      make = pkgs.linux-kernel.drvAttrs.spec.env.GOLCONDA_KERNEL_MAKE;
    in
    make == pkgs.linux-kernel.args.env.GOLCONDA_KERNEL_MAKE
  ))
  (check "checks: native package tests are required outputs" (
    builtins.all
      (name: f.checks.x86_64-linux.${name}.drvPath == f.packages.x86_64-linux.${name}.drvPath)
      [
        "tests-gnupg"
        "tests-uutils-coreutils"
      ]
  ))
  (check "cross: package sets expose target CPU and UEFI names" (
    let
      x86Set = import ../../nix/packages.nix {
        inherit sources;
        system = "x86_64-linux";
        platform = "x86_64-linux";
      };
      armSet = import ../../nix/packages.nix {
        inherit sources;
        system = "x86_64-linux";
        platform = "aarch64-linux";
      };
    in
    # Platform names differ
    x86Set.platform.name == "x86_64-linux"
    && armSet.platform.name == "aarch64-linux"
    # CPU differs
    && x86Set.platform.cpu == "x86_64"
    && armSet.platform.cpu == "aarch64"
    # Pure platform metadata; derivation identity is not checked here.
    && x86Set.platform.names.uefi == "x64"
    && armSet.platform.names.uefi == "aa64"
  ))
  # the template fetches Golconda from its pin; here it takes this tree, so the check needs no network
  (check "examples/golconda.nix evaluates without --impure" (
    (import ../../examples/golconda.nix { golconda = f; }).platform.name == "x86_64-linux"
  ))
]
