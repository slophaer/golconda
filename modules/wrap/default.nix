# wrap module: wraps a package with argv, env, and files.
# Calls repkgs' wrap function; requires repkgs pin with wrap support.
# Example use:
#   modules.wrap {
#     options.package = pkgs.ripgrep;
#     options.argv = [ "--config-path" "{root}/share/wrap/ripgreprc" ];
#     options.files."ripgreprc" = "--smart-case\n";
#   }
{ types, ... }:
{
  name = "wrap";

  options = {
    package = {
      type = types.derivation;
      description = "The package to wrap.";
    };
    argv = {
      type = types.listOf types.string;
      default = [ ];
      description = "Arguments to prepend before the user's.";
    };
    env = {
      type = types.attrsOf types.attrs;
      default = { };
      description = "Environment operations: { VAR = { op = value; }; }.";
    };
    files = {
      type = types.attrsOf types.string;
      default = { };
      description = "Files to write under share/wrap/<name>/.";
    };
  };

  # The impl returns a derivation by calling repkgs' wrap function.
  # This requires the repkgs set to be passed as an input.
  # Since adios modules don't have direct access to inputs, this is called
  # from the package expression that uses this module's output.
  impl =
    { options }:
    # The module returns the options as-is; the caller (e.g. packages.nix)
    # passes these to repkgs.wrap. This keeps the module pure and typed.
    {
      inherit (options)
        package
        argv
        env
        files
        ;
    };
}
