# lib/usr-tree.nix: assemble the complete /usr tree from the composer output.
#
# usrTree { composerOutput; platform; version; buildSystem?; sbomDrv?; sources; } → derivation
# whose output is the /usr tree: the runtime closure under nix/store, the links (a `farm` link
# expanded file by file, copied in the unit directories), bin/<name> for each executable a
# package exports, the units, sysusers and tmpfiles lines, os-release, packages.json and
# attribution.json, and the files. A bin/ name from two sources stops the build, and so does a
# program a unit runs that is not in the tree. The paths and the build-time checks are in
# docs/reference/image.md; the layout's reasons in docs/design/layout.md. The tree has no mtimes:
# mkfs.erofs -T applies the version's timestamp (lib/version.nix).
_:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    filter
    head
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

  # One os-release value, quoted for a shell and for systemd: os-release(5) wants a value with a
  # space or a special character in quotes, and a shell that sources the file reads them the same
  # way. Double quotes, with \, $, " and ` escaped. Every value is quoted, so none is missed.
  quoteOsReleaseValue =
    v: "\"" + replaceStrings [ "\\" "$" "\"" "`" ] [ "\\\\" "\\$" "\\\"" "\\`" ] v + "\"";

  # Render os-release from the template, with the target platform's architecture and systemd's
  # clock epoch. The image id (ID=, IMAGE_ID=) is /system.name: what sysupdate matches artifacts
  # against.
  renderOsRelease =
    {
      version,
      platform,
      imageId,
      systemdEpoch,
    }:
    let
      arch = platform.cpu;
      osReleaseTemplate = import ../image/os-release.nix { inherit imageId; };
    in
    concatStringsSep "\n" (
      map (
        k:
        "${k}=${
          quoteOsReleaseValue (
            replaceStrings
              [
                "{version}"
                "{arch}"
                "{systemdEpoch}"
              ]
              [
                version
                arch
                (toString systemdEpoch)
              ]
              osReleaseTemplate.${k}
          )
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
      sources, # the pins of the system: the builder is their repkgs seed's nu
    }:
    let
      # Get nushell from the bootstrap seed for the BUILD host
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
      # (composerOutput.origins.packages); `path` keeps the store path's context
      packageList = map (p: {
        name = p.pname or (p.name or "unknown");
        version = p.version or null;
        path = p.outPath;
        origins = origins.packages.${merge.pkgKey p} or [ ];
      }) roots;

      epoch = versionLib.toEpoch version;
      # packages/systemd leaves time-epoch unset, so meson takes SOURCE_DATE_EPOCH: the [pin] date
      # of its sources.toml (repkgs' sourceDate) at midnight UTC
      systemd = head (filter (p: p.pname or null == "systemd") roots);
      osRelease = renderOsRelease {
        inherit version platform;
        imageId = composerOutput.name;
        systemdEpoch = versionLib.toEpoch (replaceStrings [ "-" ] [ "" ] systemd.sourceDate + ".0");
      };

      script = ''
        use main.nu
        main build
      '';

    in
    import ./ca-derivation.nix {
      name = "golconda-usr-${version}";
      # The derivation runs on the build host, not the target
      system = buildSystem;
      __structuredAttrs = true;
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
    renderOsRelease
    ;
}
