# lib/usr-tree.nix: assemble the complete /usr tree from the composer output.
#
# usrTree { composerOutput; platform; version; buildSystem?; sbomDrv?; } → derivation
# whose output IS the /usr tree:
#   nix/store/<hash>-* for the runtime closure of composerOutput.packages
#   bin/<name> = a symlink into nix/store for each executable of each package: the names
#     in its exports.json `bin` (what bin/ holds after the build), or only the names it
#     declares (`args.bin`) when it declares them. Read at build time: evaluation cannot see
#     what a build installs. A name from two sources (two packages, or a package and a link)
#     stops the build, and the message names the path and both sources.
#   bin/, lib/, share/... = symlinks into nix/store (composerOutput.links; a link of kind
#     "farm" names a directory, expanded file by file)
#   sbin -> bin
#   lib/systemd/system/<name> = units
#   lib/sysusers.d/golconda.conf, lib/tmpfiles.d/golconda.conf
#   lib/os-release
#   lib/golconda/packages.json: [{ name, version?, path, origins }], one entry per package
#     of composerOutput.packages, origins from composerOutput.origins.packages
#   lib/golconda/attribution.json: composerOutput.origins without packages (files, links,
#     units, sysusers, tmpfiles: key -> the origins that emitted it): which module put each
#     path in the tree; a bin/<name> link of a package has that package's origins
#   files from composerOutput.files (paths are /usr/...; the /usr prefix is stripped)
#   composerOutput.programs: the /usr/bin names the units run; the build fails when one
#     does not exist in the finished tree
#
# Cross-compilation: `buildSystem` is where the derivation runs (the build host);
# `platform` is the target. os-release includes the architecture. The packages in
# composerOutput.packages are already built for the target platform.
#
# The tree is reproducible. mtimes cannot live in a store path (Nix sets them to 1); the
# version-derived timestamp is passed on for mkfs.erofs -T, see image/erofs.nix.
# Build-time verification: no absolute symlinks, dlopen links resolve, no setuid/setgid, every
# program a unit runs is in bin/.
#
# See: docs/design/layout.md, docs/reference/image.md
_:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    map
    replaceStrings
    stringLength
    substring
    ;

  merge = import ../modules/lib/merge.nix;
  versionLib = import ./version.nix { };

  # The builder scripts (nu modules). Their test is tests/usr-tree/test.nu, outside this
  # directory, so a change to the test does not change the /usr tree.
  builderTree = builtins.path {
    path = ./usr-tree;
    name = "usr-tree-builder";
  };

  # Derive epoch from version: YYYYMMDD.N -> seconds since Unix epoch. The one grammar
  # and function for it: lib/version.nix (re-exported by lib/image/common.nix). A version
  # with an impossible date or a revision past its day throws; the /system version type
  # refuses it too. The rule from image/erofs.nix: each version has a unique increasing
  # timestamp, and no revision reaches the next date's.
  versionToEpoch = versionLib.toEpoch;

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
      sources = import ../pins;
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
      inherit (composerOutput) files;
      origins = composerOutput.origins or { };

      # attribution.json: which fragment emitted each file, link, unit and line; the
      # builder adds the bin/ links of the packages
      attribution = builtins.removeAttrs origins [ "packages" ];

      # The links map as a list of { path; target; kind; origins; }, in path order
      links = map (path: {
        inherit path;
        inherit (composerOutput.links.${path}) target kind;
        origins = origins.links.${path} or [ ];
      }) (attrNames composerOutput.links);

      # bin/ links, one entry per package: the builder reads <path>/exports.json `bin`, or
      # links only `declared` (what package.nix declares in `bin`) when it is not null
      packageBins = map (p: {
        package = merge.pkgKey p;
        path = p.outPath;
        declared = merge.declaredBin p;
        origins = origins.packages.${merge.pkgKey p} or [ ];
      }) roots;

      # packages.json: each package once, with the fragments that brought it
      # (composerOutput.packageOrigins); `path` keeps the store path's context
      packageList = map (p: {
        name = p.pname or (p.name or "unknown");
        version = p.version or null;
        path = p.outPath;
        origins = origins.packages.${merge.pkgKey p} or [ ];
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

      # The packages' bin/ links and the attribution they join
      inherit packageBins attribution;

      # The programs the units run, with the origins that run them
      programs = map (name: {
        inherit name;
        origins = origins.programs.${name} or [ ];
      }) (composerOutput.programs or [ ]);

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
    ;
}
