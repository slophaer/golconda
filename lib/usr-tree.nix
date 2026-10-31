# lib/usr-tree.nix: assemble the complete /usr tree from the composer output.
#
# usrTree { composerOutput; platform; version; buildSystem?; sbomDrv?; } → derivation
# whose output IS the /usr tree:
#   nix/store/<hash>-* for the runtime closure of composerOutput.packages
#   bin/, lib/, share/... = symlinks into nix/store (composerOutput.links; a link of kind
#     "farm" names a directory, expanded file by file)
#   sbin -> bin
#   lib/systemd/system/<name> = units
#   lib/sysusers.d/golconda.conf, lib/tmpfiles.d/golconda.conf
#   lib/os-release
#   lib/golconda/packages.json: [{ name, version?, path, origins }], one entry per package
#     of composerOutput.packages, origins from composerOutput.origins.packages
#   lib/golconda/attribution.json: composerOutput.origins without packages (files, links,
#     units, sysusers, tmpfiles: key -> the origins that emitted it), for the UI's Files view
#   files from composerOutput.files (paths are /usr/...; the /usr prefix is stripped)
#
# Cross-compilation: `buildSystem` is where the derivation runs (the build host);
# `platform` is the target. os-release includes the architecture. The packages in
# composerOutput.packages are already built for the target platform.
#
# The tree is reproducible. mtimes cannot live in a store path (Nix sets them to 1); the
# version-derived timestamp is passed on for mkfs.erofs -T, see image/erofs.nix.
# Build-time verification: no absolute symlinks, dlopen links resolve, no setuid/setgid.
#
# See: docs/design/layout.md, docs/reference/image.md
_:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    dirOf
    filter
    isString
    length
    map
    match
    replaceStrings
    stringLength
    substring
    ;

  merge = import ../modules/lib/merge.nix;

  # The builder scripts (nu modules) are stored here
  builderTree = builtins.path {
    path = ./usr-tree;
    name = "usr-tree-builder";
  };

  # Derive epoch from version: YYYYMMDD.N -> seconds since Unix epoch. The one function for
  # it: lib/image/common.nix re-exports it. A version in another format throws (the /system
  # version type refuses it too). The rule from image/erofs.nix: each version has a unique
  # increasing timestamp.
  versionToEpoch =
    version:
    let
      m = match "([0-9]{4})([0-9]{2})([0-9]{2})\\.([0-9]+)" version;
      # decimal digits to an integer; fromJSON would refuse a leading zero ("01")
      toInt =
        s:
        builtins.foldl' (acc: i: acc * 10 + builtins.fromJSON (substring i 1 s)) 0 (
          builtins.genList (i: i) (stringLength s)
        );
      year = toInt (builtins.elemAt m 0);
      month = toInt (builtins.elemAt m 1);
      day = toInt (builtins.elemAt m 2);
      rev = toInt (builtins.elemAt m 3);
      # Days since epoch (1970-01-01), simplified leap year handling
      # Each year: 365 days + 1 if leap year. Accurate enough for this purpose.
      isLeap = y: (y / 4 * 4 == y) && ((y / 100 * 100 != y) || (y / 400 * 400 == y));
      daysInMonth = [
        31
        28
        31
        30
        31
        30
        31
        31
        30
        31
        30
        31
      ];
      daysBeforeMonth =
        m: y:
        let
          months = builtins.genList (i: i) m;
          feb = if m > 1 && isLeap y then 1 else 0;
        in
        builtins.foldl' (acc: i: acc + builtins.elemAt daysInMonth i) 0 months + feb;
      # Days from 1970 to year
      daysSinceEpoch =
        let
          years = builtins.genList (i: 1970 + i) (year - 1970);
          leapDays = length (filter isLeap years);
        in
        (year - 1970) * 365 + leapDays + daysBeforeMonth (month - 1) year + day - 1;
      epoch = daysSinceEpoch * 86400 + rev;
    in
    if m == null then
      throw "versionToEpoch: '${version}' is not a version: YYYYMMDD.N, such as 20261031.1"
    else
      epoch;

  # Render os-release from the template, with the target platform's architecture. The image
  # id (ID=, IMAGE_ID=) is /system.name: what sysupdate matches artifacts against.
  renderOsRelease =
    {
      version,
      platform,
      imageId,
    }:
    let
      arch = platform.cpu;
      osReleaseTemplate = import ../image/os-release.nix { inherit imageId; };
    in
    concatStringsSep "\n" (
      map (
        k:
        "${k}=${
          replaceStrings
            [
              "{version}"
              "{arch}"
            ]
            [
              version
              arch
            ]
            osReleaseTemplate.${k}
        }"
      ) (attrNames osReleaseTemplate)
    )
    + "\n";

  # Strip /usr/ prefix from absolute paths in files
  stripUsrPrefix =
    path: if substring 0 5 path == "/usr/" then substring 5 (stringLength path - 5) path else null;

  # Convert store path target to relative symlink from the link location
  # /usr/bin/jq -> nix/store/<hash>-jq/bin/jq becomes ../nix/store/<hash>-jq/bin/jq
  # /usr/lib/systemd/system/multi-user.target.wants/sshd.service -> ../sshd.service stays as is
  makeRelative =
    linkPath: target:
    if substring 0 1 target != "/" then
      # Already relative (e.g., ../sshd.service)
      target
    else
      let
        # Count depth from /usr to link directory: /usr/bin = 1 level
        # From a file in /usr/bin/, one .. reaches /usr/
        linkDir = dirOf linkPath;
        # builtins.split returns [part, [match], part, [match], ...] so filter out lists
        stripped = substring 5 (stringLength linkDir - 5) linkDir;
        parts = filter isString (builtins.split "/" stripped);
        depth = length (filter (s: s != "") parts);
        ups = concatStringsSep "/" (builtins.genList (_: "..") depth);
        # Target is /nix/store/... -> make it nix/store/...
        targetRel =
          if substring 0 1 target == "/" then substring 1 (stringLength target - 1) target else target;
      in
      "${ups}/${targetRel}";

  # Allowed top-level directories in /usr
  allowedDirs = [
    "bin"
    "lib"
    "share"
    "nix"
    "libexec"
  ];

in
{
  # Build the /usr tree
  usrTree =
    {
      composerOutput, # The composer output (system.* attributes)
      platform, # The target platform record
      version, # Image version string
      buildSystem ? platform.name, # The build host; defaults to the target (native build)
      sbomDrv ? null, # Optional SBOM derivation; its sbom.json is copied into the tree
    }:
    let
      # Get nushell from the bootstrap seed for the BUILD host
      sources = import ../nix/sources.nix;
      bootstrap = import "${sources.repkgs}/bootstrap" {
        seed = null;
        system = buildSystem;
      };
      nu = bootstrap.seed;
      baseTools = [
        bootstrap.llvm
        bootstrap.seed
      ];

      # Nu arguments (same flags as repkgs)
      nuArgs = [
        "--no-config-file"
        "--include-path=${builderTree}"
        "--experimental-options=[cell-path-types]"
        "-c"
      ];

      # The packages whose closure we need (already built for the target platform)
      roots = composerOutput.packages;

      # Prepare data for the builder
      inherit (composerOutput)
        units
        sysusers
        tmpfiles
        ;
      # The files, and attribution.json: which fragment emitted each file, link, unit and line
      files = composerOutput.files // {
        "/usr/lib/golconda/attribution.json" = {
          text = builtins.toJSON (builtins.removeAttrs (composerOutput.origins or { }) [ "packages" ]);
          mode = "0644";
        };
      };

      # The links map as a list of { path; target; kind; }, in path order
      links = map (path: {
        inherit path;
        inherit (composerOutput.links.${path}) target kind;
      }) (attrNames composerOutput.links);

      # packages.json: each package once, with the fragments that brought it
      # (composerOutput.packageOrigins); `path` keeps the store path's context
      packageList = map (p: {
        name = p.pname or (p.name or "unknown");
        version = p.version or null;
        path = p.outPath;
        origins = composerOutput.origins.packages.${merge.pkgKey p} or [ ];
      }) roots;

      epoch = versionToEpoch version;
      osRelease = renderOsRelease {
        inherit version platform;
        imageId = composerOutput.name;
      };

      script = ''
        use main.nu
        main build
      '';

    in
    derivation {
      name = "golconda-usr-${version}";
      # The derivation runs on the build host, not the target
      system = buildSystem;
      __structuredAttrs = true;
      __contentAddressed = true;
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      builder = "${nu}/bin/nu";
      args = nuArgs ++ [ script ];
      outputs = [ "out" ];

      # Nix computes the closure and passes it as a structured reference graph
      exportReferencesGraph.closure = roots;

      # Pass data to the builder
      inherit
        roots
        packageList
        epoch
        osRelease
        version
        allowedDirs
        ;

      # The target platform name, for verification logs
      targetPlatform = platform.name;

      # Links as JSON-serializable records; kind "farm" is a directory to expand
      inherit links;

      # Files to write (path -> { text, mode })
      files = builtins.mapAttrs (path: v: {
        inherit (v) text mode;
        dest = stripUsrPrefix path;
      }) files;

      # Units (name -> text)
      inherit units;

      # Sysusers and tmpfiles lines
      inherit sysusers tmpfiles;

      # SBOM: the path to sbom.json if one was given, else null
      sbomPath = if sbomDrv != null then "${sbomDrv}/sbom.json" else null;

      # PATH for the builder
      PATH = concatStringsSep ":" (map (t: "${t}/bin") baseTools);
    };

  # Export helpers for tests
  inherit
    stripUsrPrefix
    versionToEpoch
    renderOsRelease
    makeRelative
    allowedDirs
    ;
}
