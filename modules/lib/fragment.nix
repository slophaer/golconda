# The fragment type: what every service module returns and what the composer
# (/system) merges. Keys are plain strings now; typed units come later.
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
    attrNames
    isAttrs
    isString
    match
    removeAttrs
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

  fragment = struct "fragment" {
    # unit file name -> unit file text, installed to /usr/lib/systemd/system
    units = optionalAttr (attrsOf string);
    # absolute path under /usr -> file (os-release, repart.d, sysupdate.d, ...)
    files = optionalAttr (attrsOf file);
    # systemd-sysusers lines
    sysusers = optionalAttr (listOf string);
    # systemd-tmpfiles lines
    tmpfiles = optionalAttr (listOf string);
    # closure roots that go into /usr/nix/store and the /usr/bin farm
    packages = optionalAttr (listOf derivation);
  };
in
{
  inherit fragment file mode;
}
