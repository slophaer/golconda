#! Golconda's API for downstream modules: `service`, `var`, `merge` and `fragment` of `modules/lib/`.
#! A `/local` module declares `inputs.api.path = "/golconda/api"` and reads `results.api.service.render`.
#! A provider: no options, no table, no fragment of its own (`lib/components.nix`).
#! docs/features/extending.md, "A service of your own".
{ types, ... }:
{
  name = "api";

  impl = _: {
    service = import ../../lib/service.nix { inherit types; };
    var = import ../../lib/var.nix { inherit types; };
    merge = import ../../lib/merge.nix;
    fragment = import ../../lib/fragment.nix { inherit types; };
  };
}
