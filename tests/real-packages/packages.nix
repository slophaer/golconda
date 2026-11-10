# Checks that need the real package set: the outputs, the packages' build specs as repkgs
# resolves them, the catalogue as the SBOM generator writes it, and the platforms. Moved from
# tests/eval, which reads packages as data only (tests/fixtures/repkgs).
# A function of ./default.nix's harness; it returns a list of checks.
{
  check,
  f,
  hasPrefix,
  pkgs,
  platform,
  sources,
  ...
}:
let
  inherit (builtins)
    all
    attrNames
    elem
    ;
  mkSystem =
    config:
    import ../../lib/system.nix {
      inherit sources platform config;
      system = platform;
    };
in
[
  (check "outputs: aarch64 exposes no unsupported kernel, image or OS tree" (
    let
      names = attrNames f.packages.aarch64-linux;
    in
    !(elem "kernel" names) && all (n: !(hasPrefix "image-smoke" n) && !(hasPrefix "usr-tree" n)) names
  ))
  (check "outputs: x86_64 keeps the native kernel and images, not an unsupported cross OS tree" (
    let
      native = f.packages.x86_64-linux;
    in
    native ? kernel
    && native ? image-smoke-test
    && native ? usr-tree-smoke
    && !(native ? usr-tree-smoke-aarch64)
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
        "tests-btrfs-progs"
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
  (check "catalogue: every target package with version, identifiers, origin and replacement" (
    let
      sys = mkSystem ../fixtures/downstream/server.toml;
      c = sys.catalogue;
      # the purl as the SBOM generator writes it for the same package
      inherit
        (import ../../nix/packages.nix {
          inherit sources;
          system = platform;
          downstream = ../fixtures/downstream/packages;
          replaces = [
            "openssh"
            "ripgrep"
          ];
        })
        set
        ;
      sbomPurl =
        n:
        (builtins.head (
          builtins.filter (x: x.type == "application")
            (set.sbom {
              roots = [ sys.pkgs.${n} ];
              name = "probe";
            }).bom.components
        )).purl;
    in
    c.hello == {
      version = "0.0.1";
      purl = sbomPurl "hello";
      origin = "downstream";
      replaces = null;
    }
    && c.openssh.origin == "downstream"
    && c.openssh.replaces == "golconda"
    && c.openssh.cpe == "cpe:2.3:a:example:openssh:0.0.3:*:*:*:*:*:*:*"
    && c.systemd.origin == "golconda"
    && c.systemd.cpe == "cpe:2.3:a:systemd_project:systemd:${c.systemd.version}:*:*:*:*:*:*:*"
    && c.jq.origin == "repkgs"
    && c.jq.purl == sbomPurl "jq"
    # names, not aliases: the alias cpython is not an entry, its target is
    && !(c ? cpython)
    && c ? cpython314
    && builtins.length (attrNames c) > 100
  ))
]
