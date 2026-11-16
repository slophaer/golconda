# The repkgs set for a target platform; the only place that imports repkgs. Returns
# { pkgs; platform; set; downstream; }: the target's packages, repkgs' platform record
# (nix/platforms.nix in repkgs), the full set, and for each downstream package
# { replaces = "golconda" | "repkgs" | null; }.
# `downstream` (the argument) is a downstream package directory or null; it goes after
# Golconda's own, so a name it shares replaces that package, and `replaces` (the document's
# [golconda] replaces) must list exactly those names
# (docs/design/config.md, "From document to image").
# `sources.repkgs` is the pin or the eval tests' stand-in tests/fixtures/repkgs; its files are
# named with `+`, so a local tree is read in place. `system` is the build host, `platform` the
# target (default: the build host).
{
  sources,
  system,
  platform ? system,
  # kconfig options the system requires (lib/system.nix: the built-in verity key for
  # /system.secureBoot = false); kbuild.nu fails if the policy fragment contradicts one
  kernelConfig ? { },
  # files the kernel build copies into its tree before configure, by path relative to the tree
  # (lib/system.nix: the verity certificate at the fixed path SYSTEM_TRUSTED_KEYS names)
  kernelFiles ? { },
  # the certificates /trust's options name, PEM text each (lib/system.nix): the CA bundle is built
  # from cacert's roots, plus caAnchors, minus caDistrust (packages/ca-bundle)
  caAnchors ? [ ],
  caDistrust ? [ ],
  downstream ? null,
  replaces ? [ ],
}:
let
  inherit (builtins)
    attrNames
    concatMap
    elem
    filter
    listToAttrs
    mapAttrs
    pathExists
    readDir
    ;

  golcondaPackages = import ../packages;
  downstreamPackages =
    if downstream == null then
      { }
    else
      listToAttrs (
        map (n: {
          name = n;
          value = downstream + "/${n}";
        }) (filter (n: pathExists (downstream + "/${n}/package.nix")) (attrNames (readDir downstream)))
      );
  # the names repkgs' own tree has, by shard (pkgs/<shard>/<name>/package.nix), the way its
  # set lists them
  repkgsNames =
    let
      root = sources.repkgs + "/pkgs";
    in
    concatMap (
      shard:
      filter (n: pathExists (root + "/${shard}/${n}/package.nix")) (
        attrNames (readDir (root + "/${shard}"))
      )
    ) (filter (s: (readDir root).${s} == "directory") (attrNames (readDir root)));
  downstreamInfo = mapAttrs (n: _: {
    replaces =
      if golcondaPackages ? ${n} then
        "golconda"
      else if elem n repkgsNames then
        "repkgs"
      else
        null;
  }) downstreamPackages;

  replacementError = (import ../lib/config.nix { tree = null; }).replacementError {
    downstream = downstreamInfo;
    allowed = replaces;
  };
  # every use of the downstream packages, or the record of them, sees the refusal
  checked = v: if replacementError != null then throw replacementError else v;

  # Kernel config: the base config plus IPE boot policy path substitution.
  # builtins.toFile embeds the policy's store path so the kernel build can read it.
  # Use builtins.path for explicit store copy (satisfies iets path-copy lint).
  ipePolicyFile = builtins.path {
    path = ../packages/kernel/ipe-boot-policy;
    name = "ipe-boot-policy";
  };
  baseKernelConfig = builtins.readFile ../packages/kernel/golconda.config;
  fullKernelConfig = baseKernelConfig + ''
    # --- IPE boot policy (path substituted at eval time) ---
    CONFIG_IPE_BOOT_POLICY="${ipePolicyFile}"
  '';
  kernelConfigFragment = builtins.toFile "golconda.config" fullKernelConfig;

  set = import (sources.repkgs + "/nix/set.nix") {
    inherit system platform;
    # a package with the name of a repkgs alias (pkgs/aliases.toml: cpython -> cpython314) would
    # be hidden by it: repkgs refuses the set
    packages = checked (golcondaPackages // downstreamPackages);
    overrides = {
      # The system's required options and the policy fragment, read by packages/kernel/kbuild.nu.
      # The package owns its base config and make flags; this replaces only these three fields.
      linux-kernel.env.merge = {
        GOLCONDA_KERNEL_EXTRA_CONFIG = builtins.toJSON kernelConfig;
        GOLCONDA_KERNEL_FRAGMENTS = builtins.toJSON [ kernelConfigFragment ];
        GOLCONDA_KERNEL_FILES = builtins.toJSON kernelFiles;
      };
      # /trust's options: the lists the bundle is made from, as JSON
      ca-bundle.env.merge = {
        GOLCONDA_CA_ANCHORS = builtins.toJSON caAnchors;
        GOLCONDA_CA_DISTRUST = builtins.toJSON caDistrust;
      };
    };
    # Set-wide choices: one TLS stack, one of each (docs/design/principles.md).
    features.tls = "openssl";
  };
in
{
  inherit (set) pkgs platform;
  inherit set;
  downstream = checked downstreamInfo;
}
