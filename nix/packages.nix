# The repkgs set for a target platform, built on the current machine.
#
# This is the only place that imports repkgs. It returns:
#   { pkgs; platform; platforms; set; downstream; }
#
# - `pkgs`: the packages for the target platform
# - `platform`: the elaborated platform record (cpu, os, name, march,
#   names.{kernel,systemd,uefi,...}; see repkgs nix/platforms.nix)
# - `platforms`: the full platforms table, for callers that build for several targets
# - `set`: the full repkgs set (all packages, as repkgs defines it)
# - `catalogue`: name -> { version; purl?; cpe?; origin; replaces?; } for every package of the
#   target set (repkgs' tree, Golconda's packages/, the downstream directory; aliases are not
#   names): the packages a package option can name. `origin` is downstream, golconda or
#   repkgs; `replaces` is on downstream entries only. purl and cpe are what the SBOM generator
#   writes for the package. A package the platform does not support is
#   { origin; supported = false; }.
# - `downstream`: name -> { replaces; } for each package of the downstream directory:
#   `replaces` is "golconda" or "repkgs" when the name was taken, else null
#
# `downstream` (the argument) is a downstream repository's package directory, or null: each
# subdirectory with a package.nix is a package (package.nix + sources.toml, as in packages/).
# It goes after Golconda's own, so a name it shares replaces that package. `replaces` (the
# document's [golconda] replaces) must list exactly the names it takes: a replacement is an
# opt-in, never an accident (lib/config.nix replacementError). mkSystem records each one in
# modules.json.
#
# `sources.repkgs` is the repkgs tree: the pin, or the eval tests' stand-in tests/fixtures/repkgs,
# which reads packages as data. Its files are named with `+`, not interpolated, so a local tree is
# read in place rather than copied to the store.
#
# Cross-compilation: `system` is the build host (builtins.currentSystem by default),
# `platform` is the target (defaults to the build host). When they differ, repkgs
# builds packages that run on the target, using the build host's toolchain.
# Example: `platform = "aarch64-linux"` on an x86_64 host builds aarch64 binaries.
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
  downstream ? null,
  replaces ? [ ],
}:
let
  on = import ../modules/lib/on.nix;
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
  # repkgs merges its aliases (pkgs/aliases.toml: cpython -> cpython314) after every package,
  # so a downstream package with an alias's name would be silently ignored: refuse it
  aliases = builtins.fromTOML (builtins.readFile (sources.repkgs + "/pkgs/aliases.toml"));
  aliasTaken = filter (n: aliases ? ${n}) (attrNames downstreamPackages);
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

  platforms = import (sources.repkgs + "/nix/platforms.nix");

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
    packages =
      if aliasTaken != [ ] then
        let
          n = builtins.head aliasTaken;
        in
        throw "golconda: downstream package ${n} has the name of a repkgs alias (${n} -> ${aliases.${n}}), which repkgs applies after every package; name the package itself (${aliases.${n}})"
      else
        checked (golcondaPackages // downstreamPackages);
    overrides = {
      # The system's required options and the policy fragment, read by packages/kernel/kbuild.nu.
      # The package owns its base config and make flags; this replaces only these three fields.
      linux-kernel.env.merge = {
        GOLCONDA_KERNEL_EXTRA_CONFIG = builtins.toJSON kernelConfig;
        GOLCONDA_KERNEL_FRAGMENTS = builtins.toJSON [ kernelConfigFragment ];
        GOLCONDA_KERNEL_FILES = builtins.toJSON kernelFiles;
      };
    };
    # Set-wide choices: one TLS stack, one of each (docs/design/principles.md).
    features.tls = "openssl";
  };
  # The generator gives a package a purl only from its own sources.toml. hwdb and gen-init-cpio
  # are built from another package's source and have none (lib/sbom-sources.nix): this sets their
  # purl to that source's, plus a subpath. The document is rebuilt with the generator's own
  # builder, so everything else in it is unchanged.
  sourcePurls = import ../lib/sbom-sources.nix;
  sourcePurl =
    n:
    let
      s = sourcePurls.${n};
      root = builtins.head (
        filter (c: c.type == "application")
          (generated {
            roots = [ set.pkgs.${s.from} ];
            name = "source";
          }).bom.components
      );
    in
    "${root.purl}#${s.subpath}";
  generated = set.sbom;
  sbom =
    args:
    let
      orig = generated args;
      bom = orig.bom // {
        components = map (
          c: if sourcePurls ? ${c.name} then c // { purl = sourcePurl c.name; } else c
        ) orig.bom.components;
      };
    in
    if !(builtins.any (c: sourcePurls ? ${c.name}) orig.bom.components) then
      orig
    else
      derivation {
        inherit (orig)
          name
          system
          builder
          args
          __contentAddressed
          outputHashMode
          outputHashAlgo
          ;
        json = builtins.toFile "sbom.json" (builtins.toJSON bom);
      }
      // {
        inherit bom;
      };
  catalogueNames = builtins.attrNames (
    listToAttrs (
      map (n: {
        name = n;
        value = null;
      }) (repkgsNames ++ attrNames golcondaPackages ++ attrNames downstreamPackages)
    )
  );
  catalogueEntry =
    n:
    let
      p = set.pkgs.${n};
      origin =
        if downstreamPackages ? ${n} then
          "downstream"
        else if golcondaPackages ? ${n} then
          "golconda"
        else
          "repkgs";
      replacement = on (downstreamInfo ? ${n}) { inherit (downstreamInfo.${n}) replaces; };
      supported = (p.supported or true) && (builtins.tryEval (builtins.deepSeq p.version true)).success;
      # the package's own component, as the SBOM generator writes it
      root = builtins.head (
        filter (c: c.type == "application")
          (sbom {
            roots = [ p ];
            name = "catalogue";
          }).bom.components
      );
    in
    if supported then
      {
        inherit origin;
      }
      // builtins.intersectAttrs {
        version = null;
        purl = null;
        cpe = null;
      } root
      // replacement
    else
      {
        inherit origin;
        supported = false;
      }
      // replacement;
in
{
  inherit (set) pkgs platform;
  inherit platforms;
  set = set // {
    inherit sbom;
  };
  downstream = checked downstreamInfo;
  catalogue = checked (
    listToAttrs (
      map (n: {
        name = n;
        value = catalogueEntry n;
      }) catalogueNames
    )
  );
}
