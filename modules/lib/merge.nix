# The union of fragments, the one rule the composer (/system) and modules that
# return more than one fragment share: attribute fields (units, files, links)
# must not repeat a key, list fields concatenate. There is no priority and no
# override; a key defined twice throws with its name (docs/design/modules.md).
#
# The /usr symlink farm is one map, path under /usr -> { target; kind; }:
# - kind "package": /usr/bin/<name> for every name in a package's `bin` list,
#   derived here from `packages`. The same package twice is one source, also
#   when a module's own `merge` already derived the link: a package link that
#   repeats a package link to the same target is no duplicate
# - the fragments' own `links`: kind "farm" (a directory the image builder
#   expands file by file), "dlopen" (a soname the builder checks) or
#   "explicit" (.wants links and the like)
# One duplicate check runs over the whole map: a path with two sources throws
# and names both, whatever their kinds. A link and a file at one path is also
# an error.
#
# Every value of `files` comes out as { text; mode; }: a plain string is a
# file with mode "0644" (fragment.nix). The image builder reads one shape.
#
#   merge [ fragmentA fragmentB ] -> { units; files; sysusers; tmpfiles; packages; links; }
#
# Attribution: `merge.withOrigins [ { origin; fragment; } ... ]` is the same
# union plus `origins`, one map per kind of thing a fragment emits, each key ->
# the origins that emitted it (each once, in first-seen order):
#   origins.packages   package key (`merge.pkgKey`: name-version)
#   origins.files      path under /usr
#   origins.links      path under /usr: the fragment's own links, and the
#                      /usr/bin links of its packages' `bin` lists
#   origins.units      unit name
#   origins.sysusers   the line
#   origins.tmpfiles   the line
# `packageOrigins` stays as an alias of `origins.packages`. The composer
# labels its inputs by module path ("/base") and a listed fragment by its
# `name` or "fragments[<i>]". `packages` stays one deduped list.
#
# `merge.linkSources fragments` lists every link with its source and
# `merge.duplicateLink sources` is the check's message or null, so a test can
# read what the error says.
let
  inherit (builtins)
    any
    attrNames
    concatLists
    concatMap
    concatStringsSep
    deepSeq
    elem
    filter
    foldl'
    isString
    listToAttrs
    mapAttrs
    ;

  path = import ./path.nix;

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

  # A package's identity: its store path; a stand-in without one goes by name.
  pkgId = p: p.outPath or (pkgName p);

  # `packages` with each package once, in first-seen order. Compared, not
  # keyed: a content-addressed output path is a placeholder that cannot be an
  # attribute name.
  uniquePackages =
    packages:
    foldl' (acc: p: if any (q: pkgId q == pkgId p) acc then acc else acc ++ [ p ]) [ ] packages;

  # The key of a package in packageOrigins: its name-version. Not the output
  # path (a placeholder for a content-addressed output) and not the .drv path
  # (a stand-in shares its parent's).
  pkgKey = pkgName;

  # key -> origins (each once, in first-seen order) from [ { origin; fragment; } ],
  # `keysOf fragment` being the keys one fragment emits
  keyOrigins =
    keysOf: labelled:
    foldl' (
      acc: l:
      foldl' (
        acc': k:
        let
          seen = acc'.${k} or [ ];
        in
        acc' // { ${k} = if elem l.origin seen then seen else seen ++ [ l.origin ]; }
      ) acc (keysOf l.fragment)
    ) { } labelled;

  originsOf = labelled: {
    packages = keyOrigins (f: map pkgKey (f.packages or [ ])) labelled;
    files = keyOrigins (f: attrNames (f.files or { })) labelled;
    links = keyOrigins (
      f:
      concatMap (p: map (b: "/usr/bin/${b}") (p.bin or [ ])) (f.packages or [ ])
      ++ attrNames (f.links or { })
    ) labelled;
    units = keyOrigins (f: attrNames (f.units or { })) labelled;
    sysusers = keyOrigins (f: f.sysusers or [ ]) labelled;
    tmpfiles = keyOrigins (f: f.tmpfiles or [ ]) labelled;
  };

  # Every link with its source, as a list of { path; target; kind; source; }:
  # /usr/bin/<name> for the packages' bin lists, then the fragments' links.
  linkSources =
    fragments:
    concatMap (
      p:
      map (b: {
        path = "/usr/bin/${b}";
        target = "${p}/bin/${b}";
        kind = "package";
        source = "package ${pkgName p}";
      }) (p.bin or [ ])
    ) (uniquePackages (concat "packages" fragments))
    ++ concatMap (
      f:
      let
        links = f.links or { };
      in
      map (path: {
        inherit path;
        inherit (links.${path}) target kind;
        source = "${links.${path}.kind} link to ${links.${path}.target}";
      }) (attrNames links)
    ) fragments;

  # The one duplicate check: the message that names both sources of the first
  # path with two, or null.
  samePackageLink = a: b: a.kind == "package" && b.kind == "package" && a.target == b.target;
  duplicateLink =
    sources:
    (foldl'
      (
        acc: l:
        if acc.err != null then
          acc
        else if acc.seen ? ${l.path} then
          if samePackageLink acc.seen.${l.path} l then
            acc
          else
            acc
            // {
              err = "golconda: ${l.path} defined twice: ${acc.seen.${l.path}.source}, ${l.source}";
            }
        else
          acc
          // {
            seen = acc.seen // {
              ${l.path} = l;
            };
          }
      )
      {
        seen = { };
        err = null;
      }
      sources
    ).err;

  # path -> { target; kind; }, after the check
  linkMap =
    sources:
    let
      err = duplicateLink sources;
    in
    if err != null then
      throw err
    else
      listToAttrs (
        map (l: {
          name = l.path;
          value = {
            inherit (l) target kind;
          };
        }) sources
      );

  # A link and a file at one path is an error.
  checkLinkFileCollision =
    links: files:
    let
      collisions = filter (p: files ? ${p}) (attrNames links);
    in
    if collisions != [ ] then
      throw "golconda: link and file at the same path: ${toString collisions}"
    else
      links;

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

  # Check that every file path is a canonical path under /usr/ (path.nix): the
  # composer compares claims by string, so a synonym such as /usr/lib/../x
  # must not reach the duplicate check. Files under /etc must go through the
  # factory module; the image holds no per-machine values (docs/design/config.md).
  checkFilePaths =
    files:
    let
      bad = filter (p: path.usrError p != null) (attrNames files);
      outside = filter (p: !(path.hasPrefix "/usr/" p)) bad;
    in
    if bad != [ ] then
      throw (
        "golconda: files must be canonical paths under /usr/: "
        + concatStringsSep "; " (map (p: path.usrError p) bad)
        + (if outside == [ ] then "" else "; /etc files go through the /factory module")
      )
    else
      files;

  # Every input gets a source label for an error message: a module sets
  # `name`; a listed fragment without one is "fragments[<i>]".
  labelFragments =
    fragments:
    builtins.genList (i: {
      origin = (builtins.elemAt fragments i).name or "fragments[${toString i}]";
      fragment = builtins.elemAt fragments i;
    }) (builtins.length fragments);

  originText = origins: concatStringsSep ", " origins;

  # The paths the composer and the builder write themselves. A fragment that
  # claims one would be overwritten in silence, so it is an error.
  reservedPaths = [
    "/usr/lib/golconda/attribution.json"
    "/usr/lib/golconda/config.json"
    "/usr/lib/golconda/packages.json"
    "/usr/lib/golconda/schema.json"
  ];
  checkReserved =
    paths:
    let
      hits = filter (p: elem p reservedPaths) paths;
    in
    if hits != [ ] then
      throw "golconda: ${concatStringsSep ", " hits} written by the system, not by a fragment: the composer or the image builder owns /usr/lib/golconda/"
    else
      true;

  # One installed path, one claim: a unit is installed at
  # /usr/lib/systemd/system/<name>, a user unit and every other file at its
  # path, a link at its path. The builder writes units, files and links into
  # one /usr tree, so a path claimed twice is an error, whatever the kinds;
  # the message names both claims and both origins.
  claimList =
    labelled:
    let
      origins = originsOf labelled;
      # os: the origins that emitted the key, from originsOf
      claim = kind: p: os: {
        path = p;
        inherit kind;
        origins = os;
      };
    in
    map (n: claim "unit '${n}'" "/usr/lib/systemd/system/${n}" origins.units.${n}) (
      attrNames origins.units
    )
    ++ map (p: claim "file" p origins.files.${p}) (attrNames origins.files)
    ++ map (p: claim "link" p origins.links.${p}) (attrNames origins.links);

  installedPathErrorOf =
    labelled:
    (foldl'
      (
        acc: c:
        if acc.err != null then
          acc
        else if acc.seen ? ${c.path} then
          acc
          // {
            err = "golconda: ${c.path} installed twice: ${acc.seen.${c.path}.kind} from ${
              originText acc.seen.${c.path}.origins
            }, ${c.kind} from ${originText c.origins}";
          }
        else
          acc
          // {
            seen = acc.seen // {
              ${c.path} = c;
            };
          }
      )
      {
        seen = { };
        err = null;
      }
      (claimList labelled)
    ).err;

  # The same check over a plain fragment list, so a test can read its message.
  installedPathError = fragments: installedPathErrorOf (labelFragments fragments);

  unionOf =
    labelled:
    let
      fragments = map (l: l.fragment) labelled;
      files = checkFilePaths (mapAttrs normalizeFile (unionNoDup "files" fragments));
      units = unionNoDup "units" fragments;
      links = checkLinkFileCollision (linkMap (linkSources fragments)) files;
      # link paths from the fragments' own maps: a package link is /usr/bin/<name>,
      # never a reserved path, and its record's target is the package's path
      reserved = checkReserved (attrNames files ++ concatMap (f: attrNames (f.links or { })) fragments);
      claimErr = installedPathErrorOf labelled;
      result = {
        inherit units files links;
        sysusers = concat "sysusers" fragments;
        tmpfiles = concat "tmpfiles" fragments;
        # each package once; the duplicate check runs before they are handed out
        packages = deepSeq (attrNames links) (uniquePackages (concat "packages" fragments));
      };
    in
    # Composition itself is the check: forcing the result (even one field)
    # runs the path and claim checks, so a collision throws here and not in
    # the builder. Link targets stay lazy: a package link's target is the
    # package's path, which a caller need not instantiate to compose.
    if claimErr != null then
      throw claimErr
    else
      builtins.seq (attrNames units) (builtins.seq (attrNames files) (builtins.seq reserved result));

  union = fragments: unionOf (labelFragments fragments);
in
{
  inherit
    linkSources
    duplicateLink
    installedPathError
    pkgKey
    ;

  withOrigins =
    labelled:
    let
      origins = originsOf labelled;
    in
    unionOf labelled
    // {
      inherit origins;
      packageOrigins = origins.packages;
    };

  __functor = _: union;
}
