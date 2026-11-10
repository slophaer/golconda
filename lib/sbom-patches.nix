# lib/sbom-patches.nix: a package's patches as CycloneDX `pedigree.patches` (1.5).
#
#   of pkg -> [ { type; diff = { url; text = { contentType; content; }; }; resolves?; } ]
#
# `pkg.patches` is the list repkgs' package.nix applies (Golconda's, repkgs' and a downstream
# package's alike). Each entry is one patch:
#   - type: "unofficial". Every patch either repository carries is its own change, not (yet)
#     an upstream release or commit (CycloneDX's backport and cherry-pick).
#   - diff.url: the file, relative to the package's directory (the component's golcondad:origin
#     says which repository); diff.text: the whole file, so the SBOM alone shows what changed.
#     CycloneDX's patch has no hash field, and the text is its own proof.
#   - resolves: one issue from the patch's own header, when it has one: `name` is the
#     `Subject:` of `git format-patch` ([PATCH …] dropped), else the first paragraph of the text
#     before the diff; `references` the URLs in that message; `type` "defect" for a subject
#     whose summary starts with "fix", else "enhancement". A bare diff resolves nothing.
_:
let
  inherit (builtins)
    baseNameOf
    concatStringsSep
    filter
    head
    isList
    isPath
    isString
    match
    readFile
    split
    stringLength
    substring
    tail
    toString
    ;

  lines = s: filter isString (split "\n" s);

  # the lines from the start up to (not including) the first line `stop` matches
  takeUntil =
    stop: ls: if ls == [ ] || stop (head ls) then [ ] else [ (head ls) ] ++ takeUntil stop (tail ls);
  dropUntil = stop: ls: if ls == [ ] || stop (head ls) then ls else dropUntil stop (tail ls);

  # the commit message: the text before the diff, and before format-patch's "---" and diffstat
  messageOf =
    content:
    takeUntil (l: l == "---" || match "(diff |--- |\\+\\+\\+ |Index: |@@ ).*" l != null) (
      lines content
    );

  # Subject: with its folded lines (a continuation starts with a blank)
  subjectOf =
    msg:
    let
      from = dropUntil (l: match "Subject: .*" l != null) msg;
      folded = takeUntil (l: match "[ \t].*" l == null) (tail from);
      raw = concatStringsSep " " (
        [ (substring 9 (stringLength (head from)) (head from)) ]
        ++ map (l: head (match "[ \t]+(.*)" l)) folded
      );
      stripped = match "\\[PATCH[ A-Za-z0-9/.-]*] *(.*)" raw;
    in
    if from == [ ] then
      null
    else if stripped == null then
      raw
    else
      head stripped;

  # the first paragraph of free text
  paragraphOf =
    msg:
    let
      p = takeUntil (l: l == "") (dropUntil (l: l != "") msg);
    in
    if p == [ ] then null else concatStringsSep " " p;

  urlsOf =
    msg:
    map head (
      filter isList (
        split "(https?://[^[:space:]<>\"]*[^[:space:]<>\".,;:)])" (concatStringsSep "\n" msg)
      )
    );

  issueOf =
    content:
    let
      msg = messageOf content;
      subject = subjectOf msg;
      name = if subject != null then subject else paragraphOf msg;
      urls = urlsOf msg;
    in
    if name == null then
      [ ]
    else
      [
        (
          {
            type = if match "([^:]+: )?[Ff]ix.*" name != null then "defect" else "enhancement";
            inherit name;
          }
          // (if urls == [ ] then { } else { references = urls; })
        )
      ];

  relativeTo =
    pkg: file:
    let
      dir = toString (pkg.dir or "") + "/";
      f = toString file;
      n = stringLength dir;
    in
    if pkg ? dir && substring 0 n f == dir then substring n (stringLength f) f else baseNameOf f;

  patchOf =
    pkg: file:
    if isPath file then
      let
        content = readFile file;
        resolves = issueOf content;
      in
      {
        type = "unofficial";
        diff = {
          url = relativeTo pkg file;
          text = {
            contentType = "text/x-diff";
            inherit content;
          };
        };
      }
      // (if resolves == [ ] then { } else { inherit resolves; })
    else
      # a fetched patch: its name only (reading it would build it during evaluation)
      {
        type = "unofficial";
        diff.url = file.name or (baseNameOf (builtins.unsafeDiscardStringContext (toString file)));
      };
in
{
  of = pkg: map (patchOf pkg) (pkg.patches or [ ]);
}
