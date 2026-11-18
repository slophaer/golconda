#! The repkgs package sets, entering the tree once: mkSystem binds `options."/pkgs".target`, the platform's set (`nix/packages.nix`), and `build`, the build host's.
#! A module that needs a package declares `inputs.pkgs.path = "/pkgs"` and reads `results.pkgs.pkgs.<name>`.
#! A module never imports repkgs and never reads a set it did not declare. `target` is not configuration data: the TOML loader refuses a `/pkgs` table.
#! docs/design/modules.md, "How packages enter the tree".
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
      throw ''golconda: /pkgs has no target set; mkSystem (lib/system.nix) binds options."/pkgs".target''
    else
      {
        inherit (options) target;
        build = options.build or { pkgs = options.target.buildPkgs; };
        inherit (options.target) pkgs;
      };
}
