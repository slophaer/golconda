# Checks of /pkgs (the package set, target and build sets) and cross-compilation.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  adios,
  check,
  f,
  fixturePkgs,
  hasInfix,
  openssh,
  sources,
  sshdTree,
  standIn,
  stubSet,
  system,
  throws,
  usrTreeLib,
  withPkgs,
  ...
}:
let
  inherit (builtins)
    attrNames
    deepSeq
    elem
    tryEval
    ;

  # the set enters once: a tree without /pkgs cannot build what needs a package
  noSet = f.modules { options."/services/sshd" = { }; };
  pkgsResult = (withPkgs { }).modules.pkgs { };
  # a cross set: the host's packages are other than the target's
  crossBuildPkgs = {
    host = true;
  };
  crossPkgs =
    extra:
    (f.modules {
      options."/pkgs" = {
        target = stubSet // {
          buildPkgs = crossBuildPkgs;
        };
      }
      // extra;
    }).modules.pkgs
      { };
in
[
  (check "checks: native package tests are required outputs" (
    builtins.all
      (name: f.checks.x86_64-linux.${name}.drvPath == f.packages.x86_64-linux.${name}.drvPath)
      [
        "tests-gnupg"
        "tests-btrfs-progs"
        "tests-uutils-coreutils"
      ]
  ))
  (check "pkgs: /pkgs returns the set and its pkgs, nothing else" (
    pkgsResult.target.pkgs == stubSet.pkgs
    && pkgsResult.pkgs.openssh == openssh
    &&
      attrNames pkgsResult == [
        "build"
        "pkgs"
        "target"
      ]
  ))
  (check "pkgs: sshd takes openssh from the set" (
    elem fixturePkgs.openssh system.packages
    && (sshdTree { package = standIn; }).modules.services.modules.sshd.args.options.package == standIn
  ))
  (check "pkgs: without the set, sshd and /pkgs throw" (
    throws (noSet.modules.services.modules.sshd { }) && !(tryEval (noSet.modules.pkgs { })).success
  ))
  (check "pkgs: the set must have pkgs" (
    let
      setThrows =
        set:
        !(tryEval (
          builtins.seq ((f.modules { options."/pkgs".target = set; }).modules.pkgs { }).target true
        )).success;
    in
    setThrows { pkgs = [ ]; }
    && setThrows { wrap = _: null; }
    && setThrows "repkgs"
    && !setThrows stubSet
  ))
  # 9. Cross-compilation: platform flows through the module tree
  (check "cross: platform record flows to os-release" (
    let
      x86 = {
        name = "x86_64-linux";
        cpu = "x86_64";
      };
      arm = {
        name = "aarch64-linux";
        cpu = "aarch64";
      };
      osX86 = usrTreeLib.renderOsRelease {
        imageId = "t";
        version = "20261031.1";
        platform = x86;
      };
      osArm = usrTreeLib.renderOsRelease {
        imageId = "t";
        version = "20261031.1";
        platform = arm;
      };
    in
    hasInfix "ARCHITECTURE=x86_64" osX86
    && hasInfix "ARCHITECTURE=aarch64" osArm
    && hasInfix "VERSION_ID=20261031.1" osX86
    && hasInfix "IMAGE_VERSION=20261031.1" osArm
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

  # 10. Boundary tests: config-in-store boundary enforcement
  # (docs/design/config.md, docs/design/modules.md)
  # /pkgs: target and build sets
  (check "pkgs: build is the target's buildPkgs; equal to target when not cross" (
    pkgsResult.build.pkgs == pkgsResult.target.pkgs
    && pkgsResult.pkgs == pkgsResult.target.pkgs
    && (crossPkgs { }).build.pkgs == crossBuildPkgs
    && (crossPkgs { }).pkgs == stubSet.pkgs
  ))
  (check "pkgs: an explicit build set wins over the default" (
    (crossPkgs {
      build = {
        pkgs = { };
      };
    }).build.pkgs == { }
  ))
  (check "pkgs: the stale option `set` is no target: /pkgs throws" (
    !(tryEval (
      deepSeq (
        (f.modules {
          options."/pkgs".set = stubSet;
        }).modules.pkgs
        { }
      ) true
    )).success
  ))
  (check "pkgs: a module that declares no input has no results.pkgs" (
    let
      probeTree = adios.adios {
        name = "probe";
        modules = adios.adios.lib.importModules ../../modules // {
          probe = {
            name = "probe";
            impl = { results }: results;
          };
        };
      };
      probe = (probeTree { options."/pkgs".target = stubSet; }).modules.probe { };
    in
    !(probe ? pkgs) && !(probe ? target)
  ))
]
