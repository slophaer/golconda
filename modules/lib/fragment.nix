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
    listOf
    string
    derivation
    typedef'
    ;
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
    else if match "[0-7]{4}" v == null then
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
  unitSuffixes = [
    "service"
    "target"
    "socket"
    "timer"
    "path"
    "mount"
    "slice"
  ];
  unitName = typedef' "unitName" (
    v:
    if !isString v then
      "Expected a string"
    else if match "[A-Za-z0-9:_.@\\-]+\\.(${builtins.concatStringsSep "|" unitSuffixes})" v == null then
      "'${v}' is not a unit name: a stem of letters, digits, : _ . @ - and one of .${builtins.concatStringsSep " ." unitSuffixes}"
    else
      null
  );

  # Unit file text: at least one section header line, [Unit], [Service], ...
  unitText = typedef' "unitText" (
    v:
    if !isString v then
      "Expected a string"
    else if !any (l: isString l && match "[[][A-Za-z]+[]]" l != null) (split "\n" v) then
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

  # A symlink in the /usr farm: { path = "/usr/bin/jq"; target = "<store>/bin/jq"; }
  # or a .wants link: { path = "/usr/.../multi-user.target.wants/sshd.service"; target = "../sshd.service"; }
  link = struct "link" {
    path = string;
    target = string;
  };

  fragment = struct "fragment" {
    # unit file name -> unit file text, installed to /usr/lib/systemd/system
    units = optionalAttr units;
    # absolute path under /usr -> file (os-release, repart.d, sysupdate.d, ...)
    files = optionalAttr (attrsOf file);
    # systemd-sysusers lines
    sysusers = optionalAttr (listOf string);
    # systemd-tmpfiles lines
    tmpfiles = optionalAttr (listOf string);
    # closure roots that go into /usr/nix/store and the /usr/bin farm
    packages = optionalAttr (listOf derivation);
    # symlinks in the /usr farm; the composer merges and checks for duplicates
    links = optionalAttr (listOf link);
    # package name -> subdirs to link file by file into /usr ("lib/security", "lib/udev/rules.d", ...)
    farm = optionalAttr (attrsOf (listOf string));
    # package name -> sonames to link into /usr/lib for dlopen ("libtss2-esys.so.0", ...)
    dlopen = optionalAttr (attrsOf (listOf string));
  };
in
{
  inherit
    fragment
    file
    mode
    link
    unitName
    unitSuffixes
    unitText
    units
    ;
}
