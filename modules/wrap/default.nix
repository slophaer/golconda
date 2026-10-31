# wrap module: wraps a package with argv, env, and files.
# Returns an app record (modules/lib/app.nix) that can be passed to `wrapApp`
# from app.nix or directly to `repkgs.wrap`.
#
# Example use:
#   let wrapped = wrapApp set.wrap (modules.wrap {
#     options.package = pkgs.ripgrep;
#     options.argv = [ "--config-path" (file "ripgreprc") ];
#     options.files.ripgreprc = "--smart-case\n";
#   });
#
# For services, pass the app record to service.app and use renderWrapped:
#   s.renderWrapped set.wrap { name = "rg"; app = modules.wrap {...}; ... }
{ types, ... }:
let
  appLib = import ../lib/app.nix { inherit types; };
in
{
  name = "wrap";

  options = {
    package = {
      type = types.derivation;
      description = "The package to wrap. Every executable in its bin/ gets a launch record.";
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

  # The impl returns an app record that the caller passes to wrapApp or repkgs.wrap.
  # Since adios modules don't have direct access to the repkgs set, the wrapping
  # happens outside the module (e.g. in packages.nix or via service.renderWrapped).
  impl =
    { options }:
    {
      inherit (options)
        package
        argv
        env
        files
        ;
    };
}
