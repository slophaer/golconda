# Extract the #! doc comment of a Nix module file: `moduleDoc path` returns the leading `#! `
# lines as Markdown (the text of the module's page), or null when there are none. The comment ends
# at the first line that does not start with `#!`. CONTRIBUTING.md: the rule for a header.
_:
let
  inherit (builtins)
    elemAt
    filter
    genList
    isString
    length
    match
    readFile
    split
    ;

  lines =
    s:
    let
      parts = split "\n" s;
    in
    filter isString parts;

  isDocComment =
    line:
    let
      m1 = match "#! (.*)" line;
      m2 = match "#!" line;
    in
    m1 != null || m2 != null;

  docContent =
    line:
    let
      m1 = match "#! (.*)" line;
      m2 = match "#!" line;
    in
    if m1 != null then
      elemAt m1 0
    else if m2 != null then
      ""
    else
      null;

  takeDocLines =
    allLines:
    let
      len = length allLines;
      findEnd =
        i:
        if i >= len then
          len
        else if isDocComment (elemAt allLines i) then
          findEnd (i + 1)
        else
          i;
      endIdx = findEnd 0;
    in
    genList (i: elemAt allLines i) endIdx;

  # Extract the doc comment from a file path, returning null if none exists.
  # The path must be a Nix path literal pointing to a file in the repo.
  moduleDoc =
    path:
    let
      content = readFile path;
      allLines = lines content;
      docLines = takeDocLines allLines;
      docContents = map docContent docLines;
    in
    if docLines == [ ] then null else builtins.concatStringsSep "\n" docContents;
in
{
  inherit moduleDoc isDocComment lines;
}
