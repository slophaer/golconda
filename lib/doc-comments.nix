# Extract #! doc comments from Nix module files.
#
# A module's documentation is written at the top of its Nix file using lines
# that start with `#! ` (hash-bang-space), mirroring Rust's `//!` module docs.
# The comment ends at the first line that does not start with `#!`.
#
# Example:
#   #! The composer: takes fragments, returns one system.
#   #!
#   #! Union with an error on a duplicate key; there is no priority system.
#   { types, ... }:
#
# Usage:
#   let docComments = import ./doc-comments.nix { };
#   in docComments.moduleDoc ./path/to/module.nix
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

  # Split a string into lines, keeping empty lines.
  lines =
    s:
    let
      parts = split "\n" s;
    in
    filter isString parts;

  # Check if a line starts with "#! " or is exactly "#!" (empty doc line).
  isDocComment =
    line:
    let
      m1 = match "#! (.*)" line;
      m2 = match "#!" line;
    in
    m1 != null || m2 != null;

  # Extract the content from a doc comment line (without "#! " or "#!").
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

  # Take lines from the start while they are doc comments.
  takeDocLines =
    allLines:
    let
      len = length allLines;
      # Find the index of the first non-doc-comment line
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
