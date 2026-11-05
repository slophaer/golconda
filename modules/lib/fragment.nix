# The fragment type: what every service module returns and what the composer
# (/system) merges. A unit is a typed name (stem plus a systemd unit suffix)
# with the rendered text as its value; the text must carry a section header.
# A full INI model is not wanted: the renderers produce text.
# modules/lib is not a module directory (no default.nix); modules import it:
#   let inherit (import ../lib/fragment.nix { inherit types; }) fragment; in ...
{ types }:
let
  inherit (types)
    struct
    optionalAttr
    attrsOf
    enum
    listOf
    string
    derivation
    typedef'
    ;
  path = import ./path.nix;
  grammar = import ./grammar.nix;
  inherit (import ./app.nix { inherit types; }) programName;
  inherit (builtins)
    any
    attrNames
    foldl'
    isAttrs
    isString
    match
    removeAttrs
    split
    ;

  # A file mode as four octal digits, "0644" or "0755".
  mode = typedef' "fileMode" (
    v:
    if !isString v then
      "Expected a file mode string like \"0644\", got ${builtins.typeOf v}"
    else if match grammar.fileMode v == null then
      "'${v}' is not a file mode: four octal digits, like \"0644\" or \"0755\""
    else
      null
  );

  # A file in a fragment: the text (installed with mode 0644), or
  # { text; mode ? "0644"; } when the mode matters (an executable). The
  # composer normalises both to { text; mode; } (merge.nix).
  file = typedef' "file" (
    v:
    if isString v then
      null
    else if !isAttrs v then
      "Expected a file: text, or { text; mode ? \"0644\"; }"
    else if !(v ? text) || !isString v.text then
      "a file record needs `text`, a string"
    else if
      removeAttrs v [
        "text"
        "mode"
      ] != { }
    then
      "a file record has only `text` and `mode`, got [${toString (attrNames v)}]"
    else if v ? mode then
      mode.verify v.mode
    else
      null
  );

  # A unit file name: a stem (letters, digits, : _ . @ -) and one of the unit
  # suffixes systemd loads from /usr/lib/systemd/system.
  inherit (grammar) unitSuffixes;
  unitName = typedef' "unitName" (
    v:
    if !isString v then
      "Expected a string"
    else if match grammar.unitName v == null then
      "'${v}' is not a unit name: a stem of letters, digits, : _ . @ - and one of .${builtins.concatStringsSep " ." unitSuffixes}"
    else
      null
  );

  # A target name, a unit name with the .target suffix: what systemd accepts for WantedBy= / RequiredBy=.
  targetName = typedef' "targetName" (
    v:
    if !isString v then
      "Expected a string"
    else if match grammar.targetName v == null then
      "'${v}' is not a valid target name (must end with .target)"
    else
      null
  );

  # Unit file text: at least one section header line, [Unit], [Service], ...
  unitText = typedef' "unitText" (
    v:
    if !isString v then
      "Expected a string"
    else if !any (l: isString l && match grammar.sectionHeader l != null) (split "\n" v) then
      "unit text has no section header such as [Unit] or [Service]"
    else
      null
  );

  # unit name -> unit text; attrsOf checks values only, so the names are
  # checked here, and an error names the unit.
  units = typedef' "units" (
    v:
    if !isAttrs v then
      "Expected type 'units' (unit name -> unit text)"
    else
      foldl' (
        err: n:
        if err != null then
          err
        else
          let
            k = unitName.verify n;
            t = unitText.verify v.${n};
          in
          if k != null then
            k
          else if t != null then
            "in unit '${n}': ${t}"
          else
            null
      ) null (attrNames v)
  );

  # What a symlink in the /usr farm is for. `farm`: the target is a
  # directory the image builder links file by file (lib/udev/rules.d of a
  # package compiled with prefix /usr); `dlopen`: a soname systemd opens by
  # name, which the builder checks resolves; `explicit`: anything else, such
  # as a .wants link with a relative target.
  linkKind = enum "linkKind" [
    "farm"
    "dlopen"
    "explicit"
  ];

  # A link target: a store path or a path relative to the link; it becomes the
  # symlink's target text, so a control character is refused.
  linkTarget = typedef' "linkTarget" (
    v:
    if !isString v then
      "Expected a string"
    else if path.hasControl v then
      "'${v}' contains a control character: a link target is one path"
    else if v == "" then
      "a link target must not be empty"
    else
      null
  );

  # One symlink: its target and kind; the path under /usr is the key in `links`.
  #   "/usr/bin/sh" = { target = "<dash>/bin/dash"; kind = "explicit"; };
  #   "/usr/lib/systemd/system/multi-user.target.wants/sshd.service" =
  #     { target = "../sshd.service"; kind = "explicit"; };
  link =
    (struct "link" {
      target = linkTarget;
      kind = linkKind;
    }).override
      { unknown = false; };

  # path under /usr -> link; attrsOf checks values only, so the keys are
  # checked here, and an error names the path.
  links = typedef' "links" (
    v:
    if !isAttrs v then
      "Expected type 'links' (path under /usr -> { target; kind; })"
    else
      foldl' (
        err: p:
        if err != null then
          err
        else if path.usrError p != null then
          path.usrError p
        else
          let
            l = link.verify v.${p};
          in
          if l != null then "in link '${p}': ${l}" else null
      ) null (attrNames v)
  );

  fragmentStruct = struct "fragment" {
    # who brought this fragment, for packageOrigins (merge.nix); a module sets its path
    name = optionalAttr string;
    # unit file name -> unit file text, installed to /usr/lib/systemd/system
    units = optionalAttr units;
    # absolute path under /usr -> file (os-release, repart.d, sysupdate.d, ...)
    files = optionalAttr (attrsOf file);
    # systemd-sysusers lines
    sysusers = optionalAttr (listOf string);
    # systemd-tmpfiles lines
    tmpfiles = optionalAttr (listOf string);
    # closure roots that go into /usr/nix/store; the image builder links their
    # executables into /usr/bin (lib/usr-tree.nix)
    packages = optionalAttr (listOf derivation);
    # path under /usr -> { target; kind; }: the symlinks of the farm (.wants, a
    # directory to expand, a dlopen soname); the composer refuses a path with two sources
    links = optionalAttr links;
    # names in /usr/bin the units run; the image builder fails when one does not exist
    # once the tree is built (evaluation cannot see what a package installs)
    programs = optionalAttr (listOf programName);
  };
  # no unknown field: a stale or misspelt one is an error, not ignored
  fragment = fragmentStruct.override { unknown = false; };
in
{
  inherit
    fragment
    file
    mode
    link
    linkKind
    links
    targetName
    unitName
    unitSuffixes
    unitText
    units
    ;
}
