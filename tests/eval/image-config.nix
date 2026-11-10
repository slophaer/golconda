# mkSystem's extraFragments beside the configured modules (the image chain's own checks, which
# need the real package set, are in tests/real-packages/image-config.nix).
{
  check,
  f,
  ...
}:
let
  marker = "/usr/lib/custom-marker";
  # the marker is a downstream module (tests/fixtures/image-workload/modules)
  modules = ../fixtures/image-workload/modules;
  config = {
    golconda = { inherit modules; };
    "/system" = {
      name = "fragment-test";
      version = "20261031.1";
    };
    "/local/marker" = { };
  };
  additive = f.lib.mkSystem {
    inherit config;
    system = "x86_64-linux";
    extraFragments = [
      {
        name = "/image/additive";
        files."/usr/lib/additive-marker".text = "additive";
      }
    ];
  };
in
[
  (check "mkSystem: extraFragments are named and added beside the configured modules" (
    additive.composed.files ? ${marker}
    && additive.composed.files."/usr/lib/additive-marker".text == "additive"
    && builtins.elem "/image/additive" additive.fragments
  ))
]
