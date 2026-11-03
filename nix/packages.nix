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
# - `downstream`: name -> { replaces; } for each package of the downstream directory:
#   `replaces` is "golconda" or "repkgs" when the name was taken, else null
#
# `downstream` (the argument) is a downstream repository's package directory, or null: each
# subdirectory with a package.nix is a package (package.nix + sources.toml, as in packages/).
# It goes after Golconda's own, so a name it shares replaces that package; mkSystem records
# the replacement in modules.json.
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
  downstream ? null,
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
      root = "${sources.repkgs}/pkgs";
    in
    concatMap (
      shard:
      filter (n: pathExists "${root}/${shard}/${n}/package.nix") (attrNames (readDir "${root}/${shard}"))
    ) (filter (s: (readDir root).${s} == "directory") (attrNames (readDir root)));
  # repkgs merges its aliases (pkgs/aliases.toml: cpython -> cpython314) after every package,
  # so a downstream package with an alias's name would be silently ignored: refuse it
  aliases = builtins.fromTOML (builtins.readFile "${sources.repkgs}/pkgs/aliases.toml");
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

  platforms = import "${sources.repkgs}/nix/platforms.nix";

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

  set = import "${sources.repkgs}/nix/set.nix" {
    inherit system platform;
    packages =
      if aliasTaken != [ ] then
        let
          n = builtins.head aliasTaken;
        in
        throw "golconda: downstream package ${n} has the name of a repkgs alias (${n} -> ${aliases.${n}}), which repkgs applies after every package; name the package itself (${aliases.${n}})"
      else
        golcondaPackages // downstreamPackages;
    overrides = {
      # The system's required options and the policy fragment, read by packages/kernel/kbuild.nu.
      # The package owns its base config and make flags; this replaces only these two fields.
      linux-kernel.env.merge = {
        GOLCONDA_KERNEL_EXTRA_CONFIG = builtins.toJSON kernelConfig;
        GOLCONDA_KERNEL_FRAGMENTS = builtins.toJSON [ kernelConfigFragment ];
      };
    };
    # Set-wide choices: one TLS stack, one of each (docs/design/principles.md).
    features.tls = "openssl";
  };
in
{
  inherit (set) pkgs platform;
  inherit platforms set;
  downstream = downstreamInfo;
}
