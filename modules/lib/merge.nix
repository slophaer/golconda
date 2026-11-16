# The union of fragments, the one rule that the composer (/system) and modules returning more than
# one fragment share: attribute fields (units, files, links) must not repeat a key, list fields
# concatenate with each element once. There is no priority and no override (docs/design/modules.md).
#
#   merge [ fragmentA fragmentB ] -> { units; files; sysusers; tmpfiles; packages; links; programs; }
#
# Every file comes out as { text; mode; }. `links` is one map, path under /usr -> { target; kind; };
# the image builder links /usr/bin/<name> from each package's exports.json (lib/usr-tree.nix),
# because evaluation cannot see what a build installs. One check covers units, files, links and
# the tmpfiles and sysusers lines: a path claimed twice throws with both claims and both origins.
# The paths that the system and the image builder write are claimed first. `merge.withOrigins`
# adds `origins` (key -> origins, first-seen order); `merge.duplicateError` is the message or null.
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
    isList
    isString
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

  pkgName = p: p.name or "${p.pname}-${p.version}";

  # The `bin` list a repkgs package declares (`pkgs.<name>.bin`, after
  # overrides), or null. What a build installs is known only at build time,
  # in its exports.json `bin`, so an undeclared package has no list here. A
  # plain derivation (a signed loader) has none, or an output named bin,
  # which is no list.
  declaredBin =
    p:
    let
      b = p.bin or null;
    in
    if isList b then b else null;

  # A package's identity: its store path; a stand-in without one goes by name.
  pkgId = p: p.outPath or (pkgName p);

  # `packages` with each package once, in first-seen order. Compared, not
  # keyed: a content-addressed output path is a placeholder that cannot be an
  # attribute name.
  uniquePackages =
    packages:
    foldl' (acc: p: if any (q: pkgId q == pkgId p) acc then acc else acc ++ [ p ]) [ ] packages;

  # The key of a package in origins.packages: its name-version. Not the output
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
    links = keyOrigins (f: attrNames (f.links or { })) labelled;
    units = keyOrigins (f: attrNames (f.units or { })) labelled;
    sysusers = keyOrigins (f: f.sysusers or [ ]) labelled;
    tmpfiles = keyOrigins (f: f.tmpfiles or [ ]) labelled;
    programs = keyOrigins (f: f.programs or [ ]) labelled;
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
    ]
    ++ by "lib/usr-tree/main.nu" [
      "/usr/lib/golconda/attribution.json"
      "/usr/lib/golconda/packages.json"
      "/usr/lib/golconda/sbom.json"
      "/usr/lib/os-release"
      "/usr/lib/sysusers.d/golconda.conf"
      "/usr/lib/tmpfiles.d/golconda.conf"
    ];

  # The fields of a sysusers or tmpfiles line, split at white space.
  fieldsOf = line: filter (x: isString x && x != "") (builtins.split "[[:space:]]+" line);

  # The key a sysusers line claims: a `u` line its user, a `g` line its group
  # (field 2). An `m` or `r` line claims nothing.
  sysusersKey =
    line:
    let
      fs = fieldsOf line;
      type = builtins.replaceStrings [ "!" ] [ "" ] (head fs);
    in
    if builtins.length fs < 2 then
      null
    else if type == "u" then
      "user ${builtins.elemAt fs 1}"
    else if type == "g" then
      "group ${builtins.elemAt fs 1}"
    else
      null;

  # The path a tmpfiles line claims (field 2).
  tmpfilesKey =
    line:
    let
      fs = fieldsOf line;
    in
    if builtins.length fs < 2 then null else builtins.elemAt fs 1;

  # Every key one labelled fragment claims, as { path; what; origin; }: a unit
  # at /usr/lib/systemd/system/<name>, a file at its path, a link at its path,
  # a tmpfiles line at its path, and a sysusers line for its user or group. A
  # line claim also has `line`: two identical lines are one claim.
  claimsOf =
    l:
    let
      f = l.fragment;
      links = f.links or { };
      claim = path: what: {
        inherit path what;
        inherit (l) origin;
      };
      lineClaims =
        field: keyOf:
        concatMap (
          line:
          let
            k = keyOf line;
          in
          if k == null then [ ] else [ (claim k "${field} line '${line}'" // { inherit line; }) ]
        ) (f.${field} or [ ]);
    in
    map (n: claim "/usr/lib/systemd/system/${n}" "unit '${n}'") (attrNames (f.units or { }))
    ++ map (p: claim p "file") (attrNames (f.files or { }))
    ++ map (p: claim p "${links.${p}.kind} link to ${links.${p}.target}") (attrNames links)
    ++ lineClaims "sysusers" sysusersKey
    ++ lineClaims "tmpfiles" tmpfilesKey;

  # The first sysusers or tmpfiles line with a control character, as an error,
  # or null: a line break would add a line.
  lineControlErrorOf =
    labelled:
    let
      linesOf = l: (l.fragment.sysusers or [ ]) ++ (l.fragment.tmpfiles or [ ]);
      bad = concatMap (
        l:
        map (line: "golconda: a line from ${l.origin} contains a control character: '${line}'") (
          filter path.hasControl (linesOf l)
        )
      ) labelled;
    in
    if bad == [ ] then null else head bad;

  # Each element once, in first-seen order.
  unique = foldl' (acc: x: if elem x acc then acc else acc ++ [ x ]) [ ];

  # The one duplicate check: one path, one claim. The message names both
  # claims and both origins.
  duplicateErrorOf =
    labelled:
    let
      claims = concatMap claimsOf labelled;
      aliases = filter (c: c.path == "/usr/sbin" || path.hasPrefix "/usr/sbin/" c.path) claims;
      byPath = groupBy (c: c.path) (reservedClaims ++ claims);
      controlError = lineControlErrorOf labelled;
      errorAt =
        path:
        let
          first = head byPath.${path};
          # an identical line is the same claim
          clash = filter (c: !(c ? line && first ? line && c.line == first.line)) (tail byPath.${path});
        in
        if clash == [ ] then
          null
        else
          "golconda: ${path} defined twice: ${first.what} from ${first.origin}, ${(head clash).what} from ${(head clash).origin}";
      errors = filter (e: e != null) (map errorAt (attrNames byPath));
    in
    if controlError != null then
      controlError
    else if aliases != [ ] then
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
      links = unionAttrs "links" fragments;
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
        sysusers = unique (concat "sysusers" fragments);
        tmpfiles = unique (concat "tmpfiles" fragments);
        programs = unique (concat "programs" fragments);
      };

  union = fragments: unionOf (labelFragments fragments);
in
{
  inherit
    declaredBin
    duplicateError
    labelFragments
    pkgKey
    ;

  withOrigins =
    labelled:
    let
      origins = originsOf labelled;
    in
    unionOf labelled // { inherit origins; };

  __functor = _: union;
}
