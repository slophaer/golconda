# lib/usr-tree.nix: assemble the complete /usr tree from the composer output.
#
# usrTree { system; pkgs; platform; version; } → derivation whose output IS the /usr tree:
#   nix/store/<hash>-* for the runtime closure of system.packages
#   bin/, lib/, share/... = symlinks into nix/store (from system.links + expanded farmDirs)
#   sbin -> bin
#   lib/systemd/system/<name> = units
#   lib/sysusers.d/golconda.conf, lib/tmpfiles.d/golconda.conf
#   lib/os-release
#   files from system.files (paths are /usr/...; the /usr prefix is stripped)
#
# The tree is reproducible: every file and directory gets a fixed mtime derived from the version.
# Build-time verification: no absolute symlinks, dlopen sonames resolve, no setuid/setgid.
#
# See: docs/design/layout.md, docs/reference/image.md
_:
let
  inherit (builtins)
    attrNames
    baseNameOf
    concatStringsSep
    dirOf
    filter
    hasContext
    isString
    length
    map
    match
    replaceStrings
    stringLength
    substring
    ;

  # The builder scripts (nu modules) are stored here
  builderTree = builtins.path {
    path = ./usr-tree;
    name = "usr-tree-builder";
  };

  # Derive epoch from version: YYYYMMDD.N -> seconds since Unix epoch
  # The rule from image/erofs.nix: each version has a unique increasing timestamp.
  # Uses Python-style date calculation: days since epoch.
  versionToEpoch =
    version:
    let
      m = match "([0-9]{4})([0-9]{2})([0-9]{2})\\.([0-9]+)" version;
      year = builtins.fromJSON (builtins.elemAt m 0);
      month = builtins.fromJSON (builtins.elemAt m 1);
      day = builtins.fromJSON (builtins.elemAt m 2);
      rev = builtins.fromJSON (builtins.elemAt m 3);
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
      # Fallback for non-date versions: use base epoch + version number
      let
        baseEpoch = 1609459200; # 2021-01-01 00:00:00 UTC
        num = builtins.tryEval (builtins.fromJSON version);
      in
      if num.success then baseEpoch + num.value else baseEpoch
    else
      epoch;

  # Render os-release from the template
  osReleaseTemplate = import ../image/os-release.nix { imageId = "golconda"; };
  renderOsRelease =
    version:
    concatStringsSep "\n" (
      map (k: "${k}=${replaceStrings [ "{version}" ] [ version ] osReleaseTemplate.${k}}") (
        attrNames osReleaseTemplate
      )
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
      platform, # The platform record
      version, # Image version string
    }:
    let
      inherit (platform) system;
      # Get nushell from the bootstrap seed (same as repkgs uses for builds)
      sources = import ../nix/sources.nix;
      bootstrap = import "${sources.repkgs}/bootstrap" {
        seed = null;
        inherit system;
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

      # The packages whose closure we need
      roots = composerOutput.packages;

      # Prepare data for the builder
      inherit (composerOutput)
        links
        farmDirs
        files
        units
        sysusers
        tmpfiles
        ;
      dlopen = builtins.listToAttrs (
        map (l: {
          name = baseNameOf l.path;
          value = l.target;
        }) (filter (l: substring 0 9 l.path == "/usr/lib/" && !(hasContext l.path)) links)
      );

      epoch = versionToEpoch version;
      osRelease = renderOsRelease version;

      script = ''
        use main.nu
        main build
      '';

    in
    derivation {
      name = "golconda-usr-${version}";
      inherit system;
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
        epoch
        osRelease
        version
        allowedDirs
        ;

      # Links as JSON-serializable records
      links = map (l: {
        inherit (l) path target;
      }) links;

      # Farm directories to expand
      farmDirs = map (d: {
        inherit (d) path target;
      }) farmDirs;

      # Files to write (path -> { text, mode })
      files = builtins.mapAttrs (path: v: {
        inherit (v) text mode;
        dest = stripUsrPrefix path;
      }) files;

      # Units (name -> text)
      inherit units;

      # Sysusers and tmpfiles lines
      inherit sysusers tmpfiles;

      # dlopen sonames to verify
      dlopenSonames = attrNames dlopen;

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
