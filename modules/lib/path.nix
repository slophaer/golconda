# Canonical paths: the checks behind every path or name that becomes a path in the installed /usr
# tree. The composer compares claims by string, so "/usr/bin/../lib/x" and "/usr/lib/x" (one
# file, two strings) are refused, not normalized. `/usr/../etc/x` passes a plain "/usr/" prefix
# check, so each check covers the whole path: under /usr/, no empty, `.` or `..` component, no
# repeated or trailing separator, no control character.
#   path.usrError, path.relativeError (a file name under /usr/lib/<service>/), path.componentError
#   return null or a message that names the path and the rule.
# Plain functions, so merge.nix can use them without the types library. Each accepts what one
# pattern of grammar.nix accepts (usrPath, relativePath, component) plus no control character;
# the rules below only pick the message for a path the pattern refuses.
let
  grammar = import ./grammar.nix;
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
  hasControl = s: length (split grammar.control s) > 1;

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
    else if match grammar.usrPath p != null then
      null
    else if !hasPrefix "/usr/" p then
      "'${p}' is not under /usr/: a file or link path in the /usr tree starts with /usr/"
    else if repeatedSeparator p then
      "'${p}' has a repeated separator: a path in the /usr tree is canonical"
    else if trailingSeparator p then
      "'${p}' ends with /: a file or link has a name"
    else if dotComponent p then
      "'${p}' has a . or .. component: a path in the /usr tree is canonical"
    else
      "'${p}' is not a canonical path under /usr/";

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
    else if match grammar.relativePath p != null then
      null
    else if hasPrefix "/" p then
      "'${p}' is absolute: a file name is relative to the directory the renderer installs it in"
    else if repeatedSeparator p then
      "'${p}' has a repeated separator: a file name is a path of plain components"
    else if trailingSeparator p then
      "'${p}' ends with /: a file name names a file"
    else if dotComponent p then
      "'${p}' has a . or .. component: a file name cannot leave its directory"
    else
      "'${p}' is not a relative file name";

  # One path component, such as a directory under /var/lib or a network name.
  componentError =
    p:
    if !isString p then
      "Expected a string"
    else if match grammar.component p != null then
      null
    else if p == "." || p == ".." then
      "'${p}' is not a name"
    else
      "'${p}' is not one path component: letters, digits, and _ . - only";
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
