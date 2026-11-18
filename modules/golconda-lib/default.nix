#! Golconda's module library for downstream modules: `service`, `var`, `merge` and `fragment` of `modules/lib/`.
#! A `/local` module declares `inputs.golconda.path = "/golconda-lib"` and reads `results.golconda.service.render`.
#! A provider: no options, no table, no fragment of its own (`lib/components.nix`).
#! docs/features/extending.md, "A service of your own".
{ types, ... }:
{
  name = "golconda-lib";

  impl = _: {
    service = import ../lib/service.nix { inherit types; };
    var = import ../lib/var.nix { inherit types; };
    merge = import ../lib/merge.nix;
    fragment = import ../lib/fragment.nix { inherit types; };
  };
}
