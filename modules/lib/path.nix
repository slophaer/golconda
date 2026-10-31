# Canonical paths: the checks behind every path or name that becomes a path
# in the installed /usr tree (review finding 10).
#
# A path from a fragment is a claim on that tree, and the composer compares
# claims by string: "/usr/bin/../lib/x" and "/usr/lib/x" are the same file
# but two strings, so a non-canonical spelling is refused, not normalized.
# `/usr/../etc/x` also passes a plain "/usr/" prefix check, so the check is
# on the whole path: under /usr/, no empty, `.` or `..` component, no
# repeated separator, no trailing separator, no control character.
#
#   path.usrError "/usr/lib/x"       # null
#   path.usrError "/usr/../etc/x"    # a message naming the path and the rule
#   path.relativeError "a/b"         # null: a file name under /usr/lib/<service>/
#   path.componentError "a b"        # a message: not one path component
#
# Plain functions, so a caller without the types library (merge.nix) can use
# them; fragment.nix, app.nix and the like wrap them as typedefs.
let
  inherit (builtins)
    any
    filter
    isString
    length
    match
    split
    stringLength
    substring
    ;

  hasPrefix = p: s: substring 0 (stringLength p) s == p;

  # A control character is anything at or below 0x1f, or 0x7f: a newline or a
  # NUL would add a line to a rendered file or truncate a name.
  hasControl = s: length (split "[[:cntrl:]]" s) > 1;

  # The components of a path; split returns the separators too, as lists.
  components = p: filter isString (split "/" p);
  dotComponent = p: any (c: c == "." || c == "..") (components p);
  repeatedSeparator = p: match ".*//.*" p != null;
  trailingSeparator = p: match ".*/$" p != null;

  controlError = p: "'${p}' contains a control character: a newline would add a line or a directive";

  # An installed path: under /usr/, canonical, named.
  usrError =
    p:
    if !isString p then
      "Expected a string"
    else if hasControl p then
      controlError p
    else if !hasPrefix "/usr/" p then
      "'${p}' is not under /usr/: a file or link path in the /usr tree starts with /usr/"
    else if repeatedSeparator p then
      "'${p}' has a repeated separator: a path in the /usr tree is canonical"
    else if trailingSeparator p then
      "'${p}' ends with /: a file or link has a name"
    else if dotComponent p then
      "'${p}' has a . or .. component: a path in the /usr tree is canonical"
    else
      null;

  # A relative file name, such as "principals/root"; it may name a directory,
  # but it cannot leave the directory the renderer puts it in.
  relativeError =
    p:
    if !isString p then
      "Expected a string"
    else if p == "" then
      "a file name must not be empty"
    else if hasControl p then
      controlError p
    else if hasPrefix "/" p then
      "'${p}' is absolute: a file name is relative to the directory the renderer installs it in"
    else if repeatedSeparator p then
      "'${p}' has a repeated separator: a file name is a path of plain components"
    else if trailingSeparator p then
      "'${p}' ends with /: a file name names a file"
    else if dotComponent p then
      "'${p}' has a . or .. component: a file name cannot leave its directory"
    else
      null;

  # One path component, such as a directory under /var/lib or a network name.
  componentError =
    p:
    if !isString p then
      "Expected a string"
    else if match "[A-Za-z0-9_.-]+" p == null then
      "'${p}' is not one path component: letters, digits, and _ . - only"
    else if p == "." || p == ".." then
      "'${p}' is not a name"
    else
      null;
in
{
  inherit
    hasControl
    hasPrefix
    usrError
    relativeError
    componentError
    ;
}
