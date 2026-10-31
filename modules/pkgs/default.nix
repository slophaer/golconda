#! The repkgs package sets, entering the tree once.
#!
#! The configuration passes the set of its platform as `options."/pkgs".target`
#! (`nix/default.nix` takes it from `nix/packages.nix`); `options."/pkgs".build`
#! is the build host's set and defaults to `{ pkgs = target.buildPkgs; }`, the
#! same set when the platform is not cross. A module that needs a package
#! declares `inputs.pkgs.path = "/pkgs"` and reads `results.pkgs.pkgs.<name>`
#! (the target's packages) or `results.pkgs.build.pkgs.<name>` (tools that run
#! on the builder); an option that holds a package defaults from there
#! (`defaultFunc = { results }: results.pkgs.pkgs.openssh`). The rule: a module
#! never imports repkgs and never reads a set it did not declare; a second kind
#! of set is a second module path, never a second argument. A configuration
#! document cannot name a package.
{ types, ... }:
let
  inherit (builtins) isAttrs typeOf;

  # The set nix/packages.nix returns: at least `pkgs`. The tests pass a stub
  # with the same shape.
  repkgsSet = types.typedef' "repkgsSet" (
    v:
    if !isAttrs v then
      "Expected the repkgs set (nix/packages.nix), got ${typeOf v}"
    else if !(v ? pkgs && isAttrs v.pkgs) then
      "the repkgs set has `pkgs`, an attribute set of packages"
    else
      null
  );
in
{
  name = "pkgs";

  options = {
    target = {
      type = repkgsSet;
      description = "The repkgs set of the platform (nix/packages.nix), passed by nix/default.nix as options.\"/pkgs\".target; not configuration data.";
    };
    build = {
      type = repkgsSet;
      description = "The repkgs set of the build host, for tools that run on the builder. Default: the `buildPkgs` of the target set (the target itself when not cross); not configuration data.";
    };
  };

  impl =
    { options }:
    if !(options ? target) then
      throw ''golconda: /pkgs has no target set: the configuration passes the repkgs set as options."/pkgs".target (nix/default.nix does); a module reads it through inputs.pkgs.path = "/pkgs"''
    else
      {
        inherit (options) target;
        build = options.build or { pkgs = options.target.buildPkgs; };
        inherit (options.target) pkgs;
      };
}
