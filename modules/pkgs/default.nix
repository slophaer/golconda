#! The repkgs package set, entering the tree once.
#!
#! The configuration passes the set of its platform as `options."/pkgs".set`
#! (`nix/default.nix` takes it from `nix/packages.nix`). A module that needs a
#! package declares `inputs.pkgs.path = "/pkgs"` and reads `results.pkgs.pkgs.<name>`
#! or `results.pkgs.wrap`; an option that holds a package defaults from there
#! (`defaultFunc = { results }: results.pkgs.pkgs.openssh`). No module imports
#! repkgs, and a configuration document cannot name a package.
{ types, ... }:
let
  inherit (builtins) isAttrs isFunction typeOf;

  # The set nix/packages.nix returns: at least `pkgs` and `wrap`. The tests
  # pass a stub with the same shape.
  repkgsSet = types.typedef' "repkgsSet" (
    v:
    if !isAttrs v then
      "Expected the repkgs set (nix/packages.nix), got ${typeOf v}"
    else if !(v ? pkgs && isAttrs v.pkgs) then
      "the repkgs set has `pkgs`, an attribute set of packages"
    else if !(v ? wrap && isFunction v.wrap) then
      "the repkgs set has `wrap`, the function that builds a launcher"
    else
      null
  );
in
{
  name = "pkgs";

  options = {
    set = {
      type = repkgsSet;
      description = "The repkgs set of the platform (nix/packages.nix), passed by nix/default.nix as options.\"/pkgs\".set; not configuration data.";
    };
  };

  impl =
    { options }:
    if !(options ? set) then
      throw ''golconda: /pkgs has no set: the configuration passes the repkgs set as options."/pkgs".set (nix/default.nix does); a module reads it through inputs.pkgs.path = "/pkgs"''
    else
      {
        inherit (options) set;
        inherit (options.set) pkgs wrap;
      };
}
