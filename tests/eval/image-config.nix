# mkSystem's extraFragments beside the configured modules, and what the public lib.mkSystem
# takes (the image chain's own checks, which need the real package set, are in
# tests/real-packages/image-config.nix).
{
  check,
  f,
  sources,
  ...
}:
let
  inherit (builtins) deepSeq tryEval;
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
  # the internal entry point: the image chain passes its own fragments
  additive = import ../../lib/system.nix {
    inherit config sources;
    system = "x86_64-linux";
    extraFragments = [
      {
        name = "/image/additive";
        files."/usr/lib/additive-marker".text = "additive";
      }
    ];
  };
  document = ../../examples/server.toml;
  refused = args: !(tryEval (deepSeq (f.lib.mkSystem args).name true)).success;
in
[
  (check "mkSystem: extraFragments are named and added beside the configured modules" (
    additive.composed.files ? ${marker}
    && additive.composed.files."/usr/lib/additive-marker".text == "additive"
    && builtins.elem "/image/additive" additive.fragments
  ))
  # the document is the whole configuration: lib.mkSystem takes it, the build host and the platform
  (check "lib.mkSystem takes config, system and platform only" (
    (f.lib.mkSystem {
      config = document;
      system = "x86_64-linux";
      platform = "x86_64-linux";
    }).name == "server"
    && refused {
      config = document;
      system = "x86_64-linux";
      extraFragments = [ ];
    }
    && refused {
      config = document;
      system = "x86_64-linux";
      inherit sources;
    }
    && refused {
      inherit config;
      system = "x86_64-linux";
    }
  ))
]
