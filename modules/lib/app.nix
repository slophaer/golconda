# The app type: what a program needs to run, with nothing systemd-specific in
# it. One core type, embedded in `service` (service.nix) and later rendered to
# a wrapped binary (repkgs `launch` records). Reports:
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

  # A credential reference, { credential = "name"; prefix ? ""; }. It renders
  # as <prefix>%d/name, which exists only inside a systemd unit, so only
  # `service.extraArgv` accepts it; `app.argv` refuses it below. The prefix
  # is for programs that take a path as `-o Option=<path>`: it is glued to
  # the path, so it is one shell word of plain characters.
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

  # argv of an app: strings only, with a clear message for the one mistake the
  # type exists to catch.
  argv = typedef' "argv" (
    v:
    if !isList v then
      "Expected type 'argv' (a list of strings)"
    else if any isCredentialRef v then
      "a credential reference belongs in service.extraArgv, not in app.argv: an app runs outside systemd and has no %d"
    else if any (a: isString a && match ".*\n.*" a != null) v then
      "an argument must not contain a newline: it would end the ExecStart= line of the unit"
    else
      (listOf string).verify v
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
  # file. A secret belongs in a credential, named from service.extraArgv.
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
              "app file '${name}' contains '${m}': an app file holds no per-machine value; a credential is named in service.extraArgv and read from %d"
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
      # default [ ]; may contain the `{files}` placeholder (see `file`)
      argv = optionalAttr argv;
      # default { }
      env = optionalAttr (attrsOf envOp);
      # file name -> text; default { }. Every renderer installs them and expands
      # `{files}`. No per-machine value: see `files`.
      files = optionalAttr files;
    }).override
      {
        verify =
          a:
          if a ? program && a.package ? bin && !builtins.elem a.program a.package.bin then
            "program '${a.program}' is not an executable of ${
              a.package.name or a.package.pname
            } (bin: [${concatStringsSep ", " a.package.bin}])"
          else
            null;
      };

  # The path of an app file, for use inside `argv`: `file "sshd_config"` is
  # "{files}/sshd_config". Each renderer expands `{files}` to where it put
  # `app.files` (the unit renderer: /usr/lib/<service>; the wrapped-binary
  # renderer: its own share directory). The same placeholder style as `launch`.
  filesPlaceholder = "{files}";
  file = name: "${filesPlaceholder}/${name}";

  # The program name: `program`, else the first of the package's `bin` list
  # (repkgs packages carry it at evaluation time, defaulting to the package
  # name). A stand-in derivation falls back to pname or name.
  binName = a: a.program or (head (a.package.bin or [ (a.package.pname or a.package.name) ]));

  # The directory for app files in a wrapped output: {root}/share/wrap/<pkgname>.
  # The `launch` record uses {root} as a placeholder expanded at run time.
  wrappedFilesDir = a: "{root}/share/wrap/${a.package.pname or a.package.name}";

  # Wrap an app into a relocatable binary that carries its own argv, env and files.
  # The wrapped derivation goes into the farm; its bin/<exe> is a launcher that
  # executes the original binary with the app's arguments and environment.
  # `wrap` is repkgs' `set.wrap` function, passed by the caller. Its output
  # declares no `bin`, and it wraps every executable of the package with the
  # same argv, so the farm links only the program: /usr/bin/<program> is the
  # launcher, nothing else of the wrapped output is reachable by name.
  # `wraps` names the package it stands in for: the farm lets the launcher
  # take /usr/bin/<program> from that package (merge.nix), not from another.
  wrapApp =
    wrap: a:
    let
      # Expand {files} in argv to the wrapped output's share directory
      expandFiles = builtins.replaceStrings [ filesPlaceholder ] [ (wrappedFilesDir a) ];
    in
    wrap {
      inherit (a) package;
      argv = builtins.map expandFiles (a.argv or [ ]);
      env = a.env or { };
      files = a.files or { };
    }
    // {
      bin = [ (binName a) ];
      wraps = a.package;
    };

  # The path a unit executes. With a wrapped binary this is still /usr/bin/<exe>
  # because the farm symlinks to the wrapped output. Keep every ExecStart= path
  # behind this one function.
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
    file
    files
    filesPlaceholder
    isCredentialRef
    perMachineMarkers
    wrapApp
    wrappedFilesDir
    ;
}
