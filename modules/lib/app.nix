# The app type: what a program needs to run, with nothing systemd-specific in
# it: package, program, argv, env and files. One core type, embedded in
# `service` (service.nix), whose renderer turns it into a unit.
#
# modules/lib is not a module directory (no default.nix); modules import it:
#   let a = import ../../lib/app.nix { inherit types; }; in ...
{ types }:
let
  inherit (types)
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
    isAttrs
    isList
    length
    ;

  inherit (builtins) isString match;

  path = import ./path.nix;

  # A value the renderer puts on one line of a unit: no control character. A
  # newline would end the directive and start another.
  unitValue = typedef' "unitValue" (
    v:
    if !isString v then
      "Expected a string"
    else if path.hasControl v then
      "'${v}' contains a control character: a value is one line of a unit"
    else
      null
  );

  # An Environment= variable name.
  envName = typedef' "envName" (
    v:
    if !isString v then
      "Expected a string"
    else if match "[A-Za-z_][A-Za-z0-9_]*" v == null then
      "'${v}' is not an environment variable name: letters, digits and _, not starting with a digit"
    else
      null
  );

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

  # `unset` is a presence marker: the key is the operation. `false` would
  # otherwise be accepted and still emit UnsetEnvironment=, so it is refused
  # instead of silently meaning something other than it says.
  unsetFlag = typedef' "unsetFlag" (
    v:
    if v == true then null else "Expected true: the key is the operation; to keep the variable, omit it"
  );

  # One launch env operation: exactly one key, and a replacement value or a
  # presence marker. Inherited-value operations (default, prepend, append)
  # are not offered: the renderer replaces the value, and systemd already
  # sets values such as PATH.
  #   { HOME = { set = "/var/lib/foo"; }; OLD = { unset = true; }; }
  envOp =
    (struct "envOp" {
      set = optionalAttr unitValue;
      unset = optionalAttr unsetFlag;
    }).override
      {
        unknown = false;
        verify =
          v:
          if length (attrNames v) == 1 then
            null
          else
            "an env operation has exactly one of set, unset; got [${concatStringsSep ", " (attrNames v)}]";
      };

  # Environment variable name -> operation; attrsOf checks values only, so the
  # names are checked here and an error names the variable.
  env = typedef' "env" (
    v:
    if !isAttrs v then
      "Expected type 'env' (environment variable name -> operation)"
    else
      builtins.foldl' (
        err: n:
        if err != null then
          err
        else
          let
            k = envName.verify n;
            o = envOp.verify v.${n};
          in
          if k != null then
            k
          else if o != null then
            "in env '${n}': ${o}"
          else
            null
      ) null (attrNames v)
  );

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
        else if path.relativeError name != null then
          "app file: ${path.relativeError name}"
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

  # The program name: a file name in /usr/bin, so no slash and no control
  # character.
  programName = typedef' "programName" (
    v:
    if !isString v then
      "Expected a string"
    else if match "[A-Za-z0-9_@.+-]+" v == null then
      "'${v}' is not a program name: letters, digits and _ @ . + - (it becomes /usr/bin/<program>)"
    else
      null
  );

  app =
    (struct "app" {
      package = derivation;
      # the executable in the package's `bin` list; default: its first entry. It
      # becomes /usr/bin/<program>, so it is one name, not a path.
      program = optionalAttr programName;
      # default [ ]; strings and credential references
      argv = optionalAttr argv;
      # default { }
      env = optionalAttr env;
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
    env
    envName
    envOp
    exe
    files
    programName
    unitValue
    isCredentialRef
    perMachineMarkers
    ;
}
