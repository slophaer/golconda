# The app type: what a program needs to run, with nothing systemd-specific in
# it: package, program, argv, env and files. One core type, embedded in
# `service` (service.nix), whose renderer turns it into a unit. Reports:
# ~/spikes/research-services/REPORT-wrappers.md section 3.
#
# modules/lib is not a module directory (no default.nix); modules import it:
#   let a = import ../../lib/app.nix { inherit types; }; in ...
{ types }:
let
  inherit (types)
    attrsOf
    bool
    derivation
    listOf
    optionalAttr
    string
    struct
    typedef'
    union
    ;
  inherit (builtins)
    any
    attrNames
    concatStringsSep
    head
    isList
    length
    ;

  inherit (builtins) isString match;

  # A credential reference, { credential = "name"; prefix ? ""; }. The
  # renderer writes it as <prefix>%d/name and checks that the service
  # declares the credential. The prefix is for programs that take a path as
  # `-o Option=<path>`: it is glued to the path, so it is one shell word of
  # plain characters.
  credentialRef =
    (struct "credentialRef" {
      credential = string;
      prefix = optionalAttr (
        typedef' "credentialPrefix" (
          v:
          if !isString v then
            "Expected a string"
          else if match "[A-Za-z0-9_=:/.,+-]*" v == null then
            "'${v}' is not a credential prefix: letters, digits and _ = : / . , + -"
          else
            null
        )
      );
    }).override
      { unknown = false; };
  isCredentialRef = v: credentialRef.verify v == null;

  # argv of an app: strings and credential references, with a clear message
  # for the one mistake the type exists to catch.
  argv = typedef' "argv" (
    v:
    if !isList v then
      "Expected type 'argv' (a list of strings and credential references)"
    else if any (a: isString a && match ".*\n.*" a != null) v then
      "an argument must not contain a newline: it would end the ExecStart= line of the unit"
    else
      (listOf (union [
        string
        credentialRef
      ])).verify
        v
  );

  # One launch env operation: exactly one key.
  #   { PATH = { prepend = [ "/usr/lib/foo/bin" ]; }; HOME = { set = "/var/lib/foo"; }; }
  envOp =
    (struct "envOp" {
      set = optionalAttr string;
      default = optionalAttr string;
      prepend = optionalAttr (listOf string);
      append = optionalAttr (listOf string);
      unset = optionalAttr bool;
    }).override
      {
        unknown = false;
        verify =
          v:
          if length (attrNames v) == 1 then
            null
          else
            "an env operation has exactly one of set, default, prepend, append, unset; got [${concatStringsSep ", " (attrNames v)}]";
      };

  # One image serves every machine, so an app file holds no per-machine
  # value (docs/design/modules.md). A credential path or a key is the one
  # that gets pasted by mistake; the type refuses the markers and names the
  # file. A secret belongs in a credential, referenced from argv.
  perMachineMarkers = [
    "%d/"
    "$CREDENTIALS_DIRECTORY"
    "/etc/credstore"
    "-----BEGIN"
    "PRIVATE KEY"
  ];
  hasInfix =
    needle: hay:
    let
      n = builtins.stringLength needle;
      h = builtins.stringLength hay;
    in
    n <= h && any (i: builtins.substring i n hay == needle) (builtins.genList (i: i) (h - n + 1));
  files = typedef' "appFiles" (
    v:
    if !builtins.isAttrs v then
      "Expected type 'appFiles' (file name -> text)"
    else
      builtins.foldl' (
        err: name:
        if err != null then
          err
        else if !isString v.${name} then
          "app file '${name}' must be text"
        else
          builtins.foldl' (
            err: m:
            if err != null then
              err
            else if hasInfix m v.${name} then
              "app file '${name}' contains '${m}': an app file holds no per-machine value; a credential is referenced from argv and read from %d"
            else
              null
          ) null perMachineMarkers
      ) null (attrNames v)
  );

  app =
    (struct "app" {
      package = derivation;
      # the executable in the package's `bin` list; default: its first entry
      program = optionalAttr string;
      # default [ ]; strings and credential references
      argv = optionalAttr argv;
      # default { }
      env = optionalAttr (attrsOf envOp);
      # file name (may hold a directory, "principals/root") -> text; default { }.
      # The renderer installs them under /usr/lib/<service>/. No per-machine
      # value: see `files`.
      files = optionalAttr files;
    }).override
      {
        unknown = false;
        verify =
          a:
          if a ? program && a.package ? bin && !builtins.elem a.program a.package.bin then
            "program '${a.program}' is not an executable of ${
              a.package.name or a.package.pname
            } (bin: [${concatStringsSep ", " a.package.bin}])"
          else
            null;
      };

  # The program name: `program`, else the first of the package's `bin` list
  # (repkgs packages carry it at evaluation time, defaulting to the package
  # name). A stand-in derivation falls back to pname or name.
  binName = a: a.program or (head (a.package.bin or [ (a.package.pname or a.package.name) ]));

  # The path a unit executes: the program in the /usr/bin farm. Keep every
  # ExecStart= path behind this one function.
  exe = a: "/usr/bin/${binName a}";
in
{
  inherit
    app
    argv
    binName
    credentialRef
    envOp
    exe
    files
    isCredentialRef
    perMachineMarkers
    ;
}
