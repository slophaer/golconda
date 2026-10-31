#! Wraps a package with argv, env, and files: a launcher from data.
#!
#! Returns the wrapped derivation (`wrapApp` in `modules/lib/app.nix` over
#! repkgs' `wrap` from `/pkgs`): a relocatable package whose `bin/<program>`
#! runs the original binary with the arguments, environment and files baked
#! in. Put it in a fragment's `packages`; it stands in for the program of the
#! package it wraps in `/usr/bin`.
#!
#! A service does not use this module: `service.app` carries the same record
#! and `renderWrapped` wraps it.
{ types, ... }:
let
  appLib = import ../lib/app.nix { inherit types; };
in
{
  name = "wrap";

  inputs.pkgs.path = "/pkgs";

  options = {
    package = {
      type = types.derivation;
      description = "The package to wrap; its first `bin` entry is the program the launcher stands in for.";
    };
    argv = {
      type = appLib.argv;
      default = [ ];
      description = ''Arguments to prepend before the user's. Use `file "name"` from app.nix for config files; it expands to {root}/share/wrap/<pkgname>/name in the wrapped output.'';
    };
    env = {
      type = types.attrsOf appLib.envOp;
      default = { };
      description = "Environment operations: { VAR = { set = value; }; }. One of set, default, prepend, append, unset.";
    };
    files = {
      type = appLib.files;
      default = { };
      description = "Files to write, name to text. They land in share/wrap/<pkgname>/<name>; reference them with `file \"name\"` in argv.";
    };
  };

  impl =
    { options, results }:
    appLib.wrapApp results.pkgs.wrap {
      inherit (options)
        package
        argv
        env
        files
        ;
    };
}
