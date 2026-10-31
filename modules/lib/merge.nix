# The union of fragments, the one rule the composer (/system) and modules that
# return more than one fragment share: attribute fields (units, files) must
# not repeat a key, list fields concatenate. There is no priority and no
# override; a key defined twice throws with its name (docs/design/modules.md).
#
# The composer also builds the /usr symlink farm:
# - /usr/bin/<name> from packages' `bin` lists
# - /usr/<subdir>/<file> from `farm` declarations (modules specify which subdirs)
# - /usr/lib/<soname> from `dlopen` declarations (for systemd's dlopen)
# - explicit links from fragments (e.g., .wants symlinks for unit enablement)
#
# Duplicates (two sources for the same /usr path) are errors with both sources
# named. A link and a file at the same path is also an error.
#
# Every value of `files` comes out as { text; mode; }: a plain string is a
# file with mode "0644" (fragment.nix). The image builder reads one shape.
#
#   merge [ fragmentA fragmentB ] -> { units; files; sysusers; tmpfiles; packages; links; }
let
  inherit (builtins)
    attrNames
    concatLists
    deepSeq
    elem
    filter
    foldl'
    isString
    listToAttrs
    mapAttrs
    ;

  normalizeFile =
    _: v:
    if isString v then
      {
        text = v;
        mode = "0644";
      }
    else
      {
        inherit (v) text;
        mode = v.mode or "0644";
      };

  # repkgs packages carry `bin`, their executable names, at evaluation time.
  pkgName = p: p.name or "${p.pname}-${p.version}";

  # A package's identity for the duplicate check: its store path; a stand-in
  # without one goes by name.
  pkgId = p: p.outPath or (pkgName p);

  # Build /usr/bin links from packages' bin lists. Two packages with the same
  # bin name is an error with both package names, no exceptions. The same
  # package listed twice is not a clash (same identity); we emit one link.
  binLinks =
    packages:
    foldl'
      (
        acc: p:
        let
          pn = pkgName p;
        in
        foldl' (
          acc: b:
          let
            path = "/usr/bin/${b}";
            source = "package ${pn}";
            link = {
              inherit path;
              target = "${p}/bin/${b}";
            };
            prior = acc.seen.${path} or null;
            take = {
              seen = acc.seen // {
                ${path} = link // {
                  inherit source;
                  package = p;
                };
              };
              links = filter (l: l.path != path) acc.links ++ [ link ];
            };
          in
          if prior == null then
            take
          else if pkgId prior.package == pkgId p then
            acc
          else
            throw "golconda: ${path} defined twice: ${prior.source}, ${source}"
        ) acc (p.bin or [ ])
      )
      {
        seen = { };
        links = [ ];
      }
      packages;

  # Build links from farm declarations: fragment.farm = { pkgName = [ "subdir" ... ]; }
  # Each subdir is linked file by file. Since we don't have IFD, the image builder
  # verifies file existence; here we emit links for each declared subdir.
  farmLinks =
    packages: farmDecls:
    let
      pkgMap = listToAttrs (
        map (p: {
          name = pkgName p;
          value = p;
        }) packages
      );
    in
    foldl'
      (
        acc: decl:
        foldl' (
          acc: pn:
          if !(pkgMap ? ${pn}) then
            throw "golconda: farm declares '${pn}' but no package with that name"
          else
            let
              p = pkgMap.${pn};
              source = "farm ${pn}";
            in
            foldl' (
              acc: subdir:
              # The link targets the subdir; the image builder expands to individual files.
              # For collision checking, we track the subdir path as a prefix.
              let
                path = "/usr/${subdir}";
              in
              if acc.seen ? ${path} && acc.seen.${path}.source != source then
                throw "golconda: farm ${path} defined twice: ${acc.seen.${path}.source}, ${source}"
              else
                {
                  seen = acc.seen // {
                    ${path} = {
                      inherit path source;
                      target = "${p}/${subdir}";
                    };
                  };
                  # Store the package + subdir for the image builder to expand
                  dirs =
                    if acc.seen ? ${path} then
                      acc.dirs
                    else
                      acc.dirs
                      ++ [
                        {
                          inherit path;
                          target = "${p}/${subdir}";
                        }
                      ];
                }
            ) acc farmDecls.${pn}
        ) acc (attrNames decl)
      )
      {
        seen = { };
        dirs = [ ];
      }
      [ farmDecls ];

  # Build /usr/lib/<soname> links from dlopen declarations.
  dlopenLinks =
    packages: dlopenDecls:
    let
      pkgMap = listToAttrs (
        map (p: {
          name = pkgName p;
          value = p;
        }) packages
      );
    in
    foldl'
      (
        acc: pn:
        if !(pkgMap ? ${pn}) then
          throw "golconda: dlopen declares '${pn}' but no package with that name"
        else
          let
            p = pkgMap.${pn};
            source = "dlopen ${pn}";
          in
          foldl' (
            acc: soname:
            let
              path = "/usr/lib/${soname}";
            in
            if acc.seen ? ${path} && acc.seen.${path}.source != source then
              throw "golconda: ${path} defined twice: ${acc.seen.${path}.source}, ${source}"
            else
              {
                seen = acc.seen // {
                  ${path} = {
                    inherit path source;
                    target = "${p}/lib/${soname}";
                  };
                };
                links =
                  if acc.seen ? ${path} then
                    acc.links
                  else
                    acc.links
                    ++ [
                      {
                        inherit path;
                        target = "${p}/lib/${soname}";
                      }
                    ];
              }
          ) acc dlopenDecls.${pn}
      )
      {
        seen = { };
        links = [ ];
      }
      (attrNames dlopenDecls);

  # Merge explicit links from fragments (e.g., .wants symlinks).
  explicitLinks =
    fragments:
    foldl'
      (
        acc: f:
        foldl' (
          acc: link:
          let
            inherit (link) path;
            source = "explicit link";
          in
          if acc.seen ? ${path} && acc.seen.${path}.source != source then
            throw "golconda: ${path} defined twice: ${acc.seen.${path}.source}, ${source}"
          else
            {
              seen = acc.seen // {
                ${path} = link // {
                  inherit source;
                };
              };
              links = if acc.seen ? ${path} then acc.links else acc.links ++ [ link ];
            }
        ) acc (f.links or [ ])
      )
      {
        seen = { };
        links = [ ];
      }
      fragments;

  # Check that no link path collides with a file path.
  checkLinkFileCollision =
    links: files:
    let
      filePaths = attrNames files;
      linkPaths = map (l: l.path) links;
      collisions = filter (p: elem p filePaths) linkPaths;
    in
    if collisions != [ ] then
      throw "golconda: link and file at the same path: ${toString collisions}"
    else
      links;

  # Merge all link sources, checking for duplicates across sources.
  mergeAllLinks = binResult: farmResult: dlopenResult: explicitResult: {
    links = binResult.links ++ dlopenResult.links ++ explicitResult.links;
    farmDirs = farmResult.dirs;
  };

  unionNoDup =
    field: fragments:
    foldl' (
      acc: f:
      let
        new = f.${field} or { };
        dup = filter (k: acc ? ${k}) (attrNames new);
      in
      if dup != [ ] then throw "golconda: ${field} defined twice: ${toString dup}" else acc // new
    ) { } fragments;

  concat = field: fragments: concatLists (map (f: f.${field} or [ ]) fragments);

  # Merge farm declarations from all fragments.
  mergeFarm =
    fragments:
    foldl' (
      acc: f:
      let
        new = f.farm or { };
        # Each package name can only be declared once
        dup = filter (k: acc ? ${k}) (attrNames new);
      in
      if dup != [ ] then
        throw "golconda: farm declared twice for package: ${toString dup}"
      else
        acc // new
    ) { } fragments;

  # Merge dlopen declarations from all fragments.
  mergeDlopen =
    fragments:
    foldl' (
      acc: f:
      let
        new = f.dlopen or { };
        # Allow merging dlopen lists for the same package
      in
      foldl' (acc: pn: acc // { ${pn} = (acc.${pn} or [ ]) ++ new.${pn}; }) acc (attrNames new)
    ) { } fragments;
  # Check that all file paths start with /usr/. Files under /etc must go through
  # the factory module; the image holds no per-machine values (docs/design/config.md).
  checkFilePaths =
    files:
    let
      hasPrefix = p: s: builtins.substring 0 (builtins.stringLength p) s == p;
      badPaths = filter (p: !(hasPrefix "/usr/" p)) (attrNames files);
    in
    if badPaths != [ ] then
      throw "golconda: files must be under /usr/; paths outside it: ${toString badPaths}; /etc files go through the /factory module"
    else
      files;
in
fragments:
let
  packages = concat "packages" fragments;
  farmDecls = mergeFarm fragments;
  dlopenDecls = mergeDlopen fragments;
  rawFiles = mapAttrs normalizeFile (unionNoDup "files" fragments);
  files = checkFilePaths rawFiles;

  binResult = binLinks packages;
  farmResult = farmLinks packages farmDecls;
  dlopenResult = dlopenLinks packages dlopenDecls;
  explicitResult = explicitLinks fragments;
  merged = mergeAllLinks binResult farmResult dlopenResult explicitResult;

  links = checkLinkFileCollision merged.links files;

  # Force all checks before returning packages. The old code did deepSeq on
  # a collision map; now the check is in binResult, which merged forces.
  checkedPackages = deepSeq merged packages;
in
{
  units = unionNoDup "units" fragments;
  inherit files;
  sysusers = concat "sysusers" fragments;
  tmpfiles = concat "tmpfiles" fragments;
  packages = checkedPackages;
  inherit links;
  # farmDirs: directories to link file by file; the image builder expands them
  inherit (merged) farmDirs;
}
