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
    match
    ;

  # A credential reference, { credential = "name"; }. It renders as %d/name,
  # which exists only inside a systemd unit, so only `service.extraArgv`
  # accepts it; `app.argv` refuses it below.
  credentialRef = (struct "credentialRef" { credential = string; }).override { unknown = false; };
  isCredentialRef = v: credentialRef.verify v == null;

  # argv of an app: strings only, with clear messages for the mistakes the
  # type exists to catch. Newlines are rejected because systemd's ExecStart=
  # cannot represent them (the unit file would be syntactically broken).
  hasNewline = s: match ".*\n.*" s != null;
  argv = typedef' "argv" (
    v:
    if !isList v then
      "Expected type 'argv' (a list of strings)"
    else if any isCredentialRef v then
      "a credential reference belongs in service.extraArgv, not in app.argv: an app runs outside systemd and has no %d"
    else if any hasNewline v then
      "argv may not contain newlines: systemd's ExecStart= cannot represent them"
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

  app = struct "app" {
    package = derivation;
    # default [ ]; may contain the `{files}` placeholder (see `file`)
    argv = optionalAttr argv;
    # default { }
    env = optionalAttr (attrsOf envOp);
    # file name -> text; default { }. Every renderer installs them and expands `{files}`.
    files = optionalAttr (attrsOf string);
  };

  # The path of an app file, for use inside `argv`: `file "sshd_config"` is
  # "{files}/sshd_config". Each renderer expands `{files}` to where it put
  # `app.files` (the unit renderer: /usr/lib/<service>; the wrapped-binary
  # renderer: its own share directory). The same placeholder style as `launch`.
  filesPlaceholder = "{files}";
  file = name: "${filesPlaceholder}/${name}";

  # The program name: repkgs packages list their binaries in `spec.bin`
  # (builder/finish.nu defaults it to the package name); the first one is the
  # program. A stand-in derivation falls back to pname or name.
  binName = a: head (a.package.spec.bin or [ (a.package.pname or a.package.name) ]);

  # SEAM: the path a unit executes. Today the binary from the /usr/bin farm;
  # the wrapped-binary renderer (repkgs `wrap`, on another branch) replaces
  # this with the wrapper, which carries argv, env and files itself. Keep
  # every ExecStart= path behind this one function.
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
    filesPlaceholder
    isCredentialRef
    ;
}
