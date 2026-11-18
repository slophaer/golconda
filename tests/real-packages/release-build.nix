# cli/build.nix, the expression `golconda release build` evaluates: from this tree, from an
# uptrack pin of Golconda (examples/pins, its fetchTarball answered with this tree), and from a
# flake.lock (its fetchTree answered with this tree), it gives mkImage's unsigned outputs of the
# document with the public halves of a key set.
{
  check,
  f,
  ...
}:
let
  pins = import ../../lib/pins.nix;
  keys = toString ../fixtures/public-keys;
  args = {
    config = ../../examples/server.toml;
    inherit keys;
    pcrKeys = keys;
    indexKeys = keys;
    system = "x86_64-linux";
  };
  inherit
    (f.lib.mkImage {
      inherit (args) config system;
      publicKeys = keys;
    })
    unsigned
    ;
  fromTree = import ../../cli/build.nix (args // { golconda = ../..; });
  # the pin's tarball is this tree, when build.nix asks for what lib.readPins fetches
  fromPin = builtins.scopedImport {
    builtins = builtins // {
      fetchTarball =
        spec:
        assert spec == (pins.specs ../../examples/pins).golconda;
        ../..;
    };
  } ../../cli/build.nix (args // { pin = ../../examples/pins/golconda/sources.toml; });
  # a flake.lock of the template's input `golconda`, locked in a node of another name
  lock = ../fixtures/flake-lock/flake.lock;
  inherit ((builtins.fromJSON (builtins.readFile lock)).nodes.golconda_2) locked;
  fromLock = builtins.scopedImport {
    builtins = builtins // {
      fetchTree =
        spec:
        assert spec == locked;
        {
          outPath = ../..;
        };
    };
  } ../../cli/build.nix (args // { inherit lock; });
in
[
  (check "release build: cli/build.nix gives mkImage's unsigned outputs of a Golconda tree" (
    fromTree.drvPath == unsigned.drvPath
  ))
  (check "release build: cli/build.nix fetches Golconda from an uptrack pin as lib.readPins does" (
    fromPin.drvPath == unsigned.drvPath
  ))
  (check "release build: cli/build.nix fetches Golconda from flake.lock as the flake does" (
    fromLock.drvPath == unsigned.drvPath
  ))
]
