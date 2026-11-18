# Checks of /pkgs (the target package set) and cross-compilation.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  adios,
  check,
  f,
  fixturePkgs,
  hasInfix,
  openssh,
  sshdTree,
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
in
[
  (check "pkgs: /pkgs returns the set and its pkgs, nothing else" (
    pkgsResult.target.pkgs == stubSet.pkgs
    && pkgsResult.pkgs.openssh == openssh
    &&
      attrNames pkgsResult == [
        "pkgs"
        "target"
      ]
  ))
  (check "pkgs: sshd takes openssh from the set, so a replacement in the set is sshd's" (
    let
      replaced = openssh // {
        outPath = "/nix/store/openssh-replaced";
      };
      sshd =
        (f.modules {
          options = {
            "/services/sshd" = { };
            "/pkgs".target = stubSet // {
              pkgs = stubSet.pkgs // {
                openssh = replaced;
              };
            };
          };
        }).modules.services.modules.sshd
          { };
    in
    elem fixturePkgs.openssh system.packages
    && elem replaced sshd.packages
    && !(elem openssh sshd.packages)
    && sshd.links."/usr/lib/ssh".target == "${replaced}/lib/ssh"
    && !((sshdTree { }).modules.services.modules.sshd.args.options ? package)
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
        systemdEpoch = 0;
        imageId = "t";
        version = "20261031.1";
        platform = x86;
      };
      osArm = usrTreeLib.renderOsRelease {
        systemdEpoch = 0;
        imageId = "t";
        version = "20261031.1";
        platform = arm;
      };
    in
    hasInfix "ARCHITECTURE=\"x86_64\"" osX86
    && hasInfix "ARCHITECTURE=\"aarch64\"" osArm
    && hasInfix "VERSION_ID=\"20261031.1\"" osX86
    && hasInfix "IMAGE_VERSION=\"20261031.1\"" osArm
  ))

  # 10. Boundary tests: config-in-store boundary enforcement
  # (docs/design/config.md, docs/design/modules.md)
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
