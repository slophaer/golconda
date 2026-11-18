#! The repkgs package set, entering the tree once: mkSystem binds `options."/pkgs".target`, the platform's set (`nix/packages.nix`).
#! A module that needs a package declares `inputs.pkgs.path = "/pkgs"` and reads `results.pkgs.pkgs.<name>`.
#! A module never imports repkgs and never reads a set it did not declare. `target` is not configuration data: the TOML loader refuses a `/pkgs` table.
#! docs/design/modules.md, "How packages enter the tree".
{ types, ... }:
let
  inherit (builtins) isAttrs isFunction typeOf;

  # The set nix/packages.nix returns: at least `pkgs` and `variant` (/trust and lib/system.nix make
  # variants). The tests pass a stub with the same shape.
  repkgsSet = types.typedef' "repkgsSet" (
    v:
    if !isAttrs v then
      "Expected the repkgs set (nix/packages.nix), got ${typeOf v}"
    else if !(v ? pkgs && isAttrs v.pkgs) then
      "the repkgs set has `pkgs`, an attribute set of packages"
    else if !(v ? variant && isFunction v.variant) then
      "the repkgs set has `variant`, a function of a package name and an override"
    else
      null
  );
in
{
  name = "pkgs";

  options = {
    target = {
      type = repkgsSet;
      description = "The repkgs set of the platform (nix/packages.nix), bound by mkSystem (lib/system.nix) as options.\"/pkgs\".target; not configuration data.";
    };
  };

  impl =
    { options }:
    if !(options ? target) then
      throw ''golconda: /pkgs has no target set; mkSystem (lib/system.nix) binds options."/pkgs".target''
    else
      {
        inherit (options) target;
        inherit (options.target) pkgs;
      };
}
