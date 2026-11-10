# A stand-in for repkgs' nix/set.nix in the eval tests (tests/eval/harness.nix passes this tree
# as `sources.repkgs`). It reads every package as data and makes no derivation: a record has
# what package.nix wrote (`args`), its directory, a version from that or the directory's
# sources.toml, the patches, and a fixed fake store path. So the eval tests never touch a real
# package, the store or repkgs' build graph; what needs the real set is in checks.* (nix/checks.nix
# real-packages).
#
# The package.nix arguments it gives: package (the arguments, as data), variant (another
# package's arguments under this name and directory), pkgs and buildPkgs (this set), sources
# (version and fetch from sources.toml) and fetch. Its own packages are pkgs/<shard>/<name>/,
# stand-ins for the repkgs packages the modules and the fixtures name.
{
  system,
  platform ? system,
  packages ? { },
  overrides ? { },
  features ? { },
}:
let
  inherit (builtins)
    attrNames
    concatMap
    convertHash
    elem
    filter
    fromTOML
    functionArgs
    hashString
    intersectAttrs
    listToAttrs
    mapAttrs
    pathExists
    readDir
    readFile
    substring
    ;
  platformRecord = (import ./platforms.nix).${platform} // {
    cross = system != platform;
  };

  # pkgs/<shard>/<name>/package.nix, as repkgs lays its tree out
  root = ../pkgs;
  own = listToAttrs (
    concatMap (
      shard:
      map
        (n: {
          name = n;
          value = root + "/${shard}/${n}";
        })
        (
          filter (n: pathExists (root + "/${shard}/${n}/package.nix")) (
            attrNames (readDir (root + "/${shard}"))
          )
        )
    ) (filter (s: (readDir root).${s} == "directory") (attrNames (readDir root)))
  );

  # a store path that looks real and is the same in every evaluation
  fakePath =
    name:
    "/nix/store/"
    + substring 0 32 (convertHash {
      hash = hashString "sha256" name;
      hashAlgo = "sha256";
      toHashFormat = "nix32";
    })
    + "-${name}";

  tomlOf =
    dir:
    if pathExists (dir + "/sources.toml") then fromTOML (readFile (dir + "/sources.toml")) else { };

  record =
    n: dir: args:
    let
      toml = tomlOf dir;
      name = args.name or n;
      version = args.version or (toml.pin.version or "0");
      merge = (overrides.${name} or { }).env.merge or { };
      supported =
        (!(args ? platforms.cpu) || elem platformRecord.cpu args.platforms.cpu)
        && (!(args ? platforms.os) || elem platformRecord.os args.platforms.os);
      unsupported = throw "repkgs stand-in: ${name} is not supported on ${platformRecord.name}";
      self = {
        type = "derivation";
        pname = name;
        name = if platformRecord.cross then "${name}-${platformRecord.name}" else name;
        inherit
          dir
          version
          args
          supported
          ;
        platform = platformRecord.name;
        patches = args.patches or [ ];
        # what repkgs' builders read: the arguments, with the set's overrides merged into env
        spec = args // {
          env = (args.env or { }) // merge;
        };
        outputName = "out";
        outPath = if supported then fakePath "${name}-${version}" else unsupported;
        drvPath = if supported then fakePath "${name}-${version}.drv" else unsupported;
      };
    in
    self // { out = self; };

  load =
    n: dir:
    let
      fn = import (dir + "/package.nix");
      toml = tomlOf dir;
      given = {
        package = record n dir;
        variant = base: over: record n dir (removeAttrs base.args [ "version" ] // over // { name = n; });
        inherit pkgs;
        buildPkgs = pkgs;
        sources = {
          version = toml.pin.version or "0";
          fetch = key: fakePath "${n}-source-${key}";
          has = _: true;
          sys = toml.pin.sys or null;
        };
        fetch = _: fakePath "${n}-fetched";
      };
    in
    fn (intersectAttrs (functionArgs fn) given);

  pkgs = mapAttrs load (own // packages);
in
{
  inherit pkgs features;
  buildPkgs = pkgs;
  platform = platformRecord;
  sbom =
    _:
    throw "repkgs stand-in: no SBOM generator in the eval tests; test the SBOM in checks.real-packages";
}
