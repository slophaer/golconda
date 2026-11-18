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
  # the set builds the package as package.nix writes it; an image's kernel is repkgs' variant of
  # it, with the verity key's extra config and file (lib/system.nix)
  (check "kernel: the set keeps the package's env; the image's variant adds the verity key only" (
    let
      own = pkgs.linux-kernel.args.env;
      final = pkgs.linux-kernel.drvAttrs.spec.env;
      image =
        (import ../../lib/system.nix {
          inherit sources;
          system = "x86_64-linux";
          config."/system" = {
            name = "t";
            version = "20261031.1";
          };
          verityCert = builtins.toFile "db.crt" "test certificate";
        }).pkgs.linux-kernel.drvAttrs.spec.env;
      same = env: names: builtins.all (n: env.${n} == own.${n}) names;
    in
    attrNames final == attrNames own
    && same final (attrNames own)
    && attrNames image == attrNames own
    && same image [
      "GOLCONDA_KERNEL_CONFIG"
      "GOLCONDA_KERNEL_FRAGMENTS"
      "GOLCONDA_KERNEL_MAKE"
    ]
    &&
      image.GOLCONDA_KERNEL_EXTRA_CONFIG == builtins.toJSON {
        SYSTEM_TRUSTED_KEYS = "certs/golconda-verity.pem";
      }
    && image.GOLCONDA_KERNEL_FILES != own.GOLCONDA_KERNEL_FILES
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
