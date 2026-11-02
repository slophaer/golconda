# The union of fragments, the one rule the composer (/system) and modules that
# return more than one fragment share: attribute fields (units, files, links)
# must not repeat a key, list fields concatenate. There is no priority and no
# override (docs/design/modules.md).
#
# The /usr symlink farm is one map, path under /usr -> { target; kind; }:
# - kind "package": /usr/bin/<name> for every name in a package's `bin` list,
#   derived here from `packages`
# - the fragments' own `links`: kind "farm" (a directory the image builder
#   expands file by file), "dlopen" (a soname the builder checks) or
#   "explicit" (.wants links and the like)
#
# One duplicate check covers the whole /usr tree. Each fragment claims paths:
# a unit /usr/lib/systemd/system/<name>, a file its path, a link its path, a
# package /usr/bin/<name> for each name in its `bin` list. A path claimed
# twice throws, whatever the kinds, and the message names both claims and both
# origins. The one exception: a package link that repeats a package link to the
# same target (one package from two fragments, or a module whose own `merge`
# already derived the link). The paths the system and the image builder write
# themselves (os-release, the golconda.conf of sysusers.d and tmpfiles.d,
# /usr/lib/golconda/*.json) are claimed before any fragment, so a fragment
# cannot claim one.
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
# `merge.duplicateError fragments` is the check's message or null, so a test
# can read what the error says.
let
  inherit (builtins)
    any
    attrNames
    concatLists
    concatMap
    concatStringsSep
    elem
    filter
    foldl'
    groupBy
    head
    isString
    listToAttrs
    mapAttrs
    tail
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

  # The paths something other than a fragment writes into /usr, with the
  # file that writes them: a fragment that claimed one would be overwritten in
  # silence. They are claims the check starts with.
  reservedClaims =
    let
      by =
        origin:
        map (p: {
          path = p;
          what = "file";
          inherit origin;
        });
    in
    by "lib/system.nix" [
      "/usr/lib/golconda/config.json"
      "/usr/lib/golconda/schema.json"
      "/usr/lib/golconda/modules.json"
    ]
    ++ by "lib/usr-tree.nix" [ "/usr/lib/golconda/attribution.json" ]
    ++ by "lib/usr-tree/main.nu" [
      "/usr/lib/golconda/packages.json"
      "/usr/lib/golconda/sbom.json"
      "/usr/lib/os-release"
      "/usr/lib/sysusers.d/golconda.conf"
      "/usr/lib/tmpfiles.d/golconda.conf"
    ];

  # Every path one labelled fragment claims in the /usr tree, as
  # { path; what; origin; target?; }: a unit at /usr/lib/systemd/system/<name>,
  # a file at its path, a link at its path, and /usr/bin/<name> for each name
  # in a package's `bin` list.
  claimsOf =
    l:
    let
      f = l.fragment;
      links = f.links or { };
      claim = path: what: {
        inherit path what;
        inherit (l) origin;
      };
    in
    map (n: claim "/usr/lib/systemd/system/${n}" "unit '${n}'") (attrNames (f.units or { }))
    ++ map (p: claim p "file") (attrNames (f.files or { }))
    ++ map (
      p:
      claim p "${links.${p}.kind} link to ${links.${p}.target}"
      // {
        inherit (links.${p}) kind target;
      }
    ) (attrNames links)
    ++ concatMap (
      p:
      map (
        b:
        claim "/usr/bin/${b}" "package ${pkgName p}"
        // {
          kind = "package";
          target = "${p}/bin/${b}";
        }
      ) (p.bin or [ ])
    ) (f.packages or [ ]);

  # The one duplicate check: one path, one claim. The exception is a package
  # link that repeats a package link to the same target (one package, two
  # fragments, or a module's own `merge` and the composer). The message names
  # both claims and both origins. Targets are compared only at a path claimed
  # twice.
  samePackageLink =
    a: b: (a.kind or null) == "package" && (b.kind or null) == "package" && a.target == b.target;
  duplicateErrorOf =
    labelled:
    let
      claims = concatMap claimsOf labelled;
      aliases = filter (c: c.path == "/usr/sbin" || path.hasPrefix "/usr/sbin/" c.path) claims;
      byPath = groupBy (c: c.path) (reservedClaims ++ claims);
      errorAt =
        path:
        let
          first = head byPath.${path};
          clash = filter (c: !(samePackageLink first c)) (tail byPath.${path});
        in
        if clash == [ ] then
          null
        else
          "golconda: ${path} defined twice: ${first.what} from ${first.origin}, ${(head clash).what} from ${(head clash).origin}";
      errors = filter (e: e != null) (map errorAt (attrNames byPath));
    in
    if aliases != [ ] then
      let
        c = head aliases;
      in
      "golconda: ${c.path} claimed by ${c.what} from ${c.origin} uses the fixed /usr/sbin alias; use /usr/bin instead"
    else if errors == [ ] then
      null
    else
      head errors;

  # The check over a plain fragment list, so a test can read its message.
  duplicateError = fragments: duplicateErrorOf (labelFragments fragments);

  # Every attribute map after the check: plain union, no key repeats.
  unionAttrs = field: fragments: foldl' (acc: f: acc // f.${field} or { }) { } fragments;

  unionOf =
    labelled:
    let
      fragments = map (l: l.fragment) labelled;
      err = duplicateErrorOf labelled;
      files = checkFilePaths (mapAttrs normalizeFile (unionAttrs "files" fragments));
      packages = uniquePackages (concat "packages" fragments);
      links =
        listToAttrs (
          concatMap (
            p:
            map (b: {
              name = "/usr/bin/${b}";
              value = {
                target = "${p}/bin/${b}";
                kind = "package";
              };
            }) (p.bin or [ ])
          ) packages
        )
        // unionAttrs "links" fragments;
    in
    # Composition itself is the check: forcing the result (even one field)
    # runs the duplicate and path checks, so a collision throws here and not
    # in the builder. Link targets stay lazy.
    if err != null then
      throw err
    else
      builtins.seq (attrNames files) {
        inherit files links packages;
        units = unionAttrs "units" fragments;
        sysusers = concat "sysusers" fragments;
        tmpfiles = concat "tmpfiles" fragments;
      };

  union = fragments: unionOf (labelFragments fragments);
in
{
  inherit
    duplicateError
    labelFragments
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
