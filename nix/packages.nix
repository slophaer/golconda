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
# target (default: the build host). One image takes one set: its kernel with the verity key
# (lib/system.nix) and its CA bundle (/trust) are variants of it (`set.variant`).
{
  sources,
  system,
  platform ? system,
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

  set = import (sources.repkgs + "/nix/set.nix") {
    inherit system platform;
    # a package with the name of a repkgs alias (pkgs/aliases.toml: cpython -> cpython314) would
    # be hidden by it: repkgs refuses the set
    packages = checked (golcondaPackages // downstreamPackages);
    # Set-wide choices: one TLS stack, one of each (docs/design/principles.md).
    features.tls = "openssl";
  };
in
{
  inherit (set) pkgs platform;
  inherit set;
  downstream = checked downstreamInfo;
}
