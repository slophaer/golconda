{
  description = "A Golconda system";

  # Golconda's main branch on its GitHub mirror. Once it has releases, pin a tag:
  # github:slophaer/golconda/v0.1. `nix flake update golconda` moves the lock.
  inputs.golconda.url = "github:slophaer/golconda";

  outputs =
    { golconda, ... }:
    let
      # The build host. A flake evaluates purely: builtins.currentSystem does not exist there,
      # so mkSystem and mkImage get it explicitly.
      system = "x86_64-linux";
      sys = golconda.lib.mkSystem {
        config = ./server.toml;
        inherit system;
      };
    in
    {
      packages.${system} = {
        # the /usr tree of server.toml: nix build
        default = sys.usrTree;
        # The image, unsigned: make the keys with Golconda's scripts/make-keys and keep them
        # outside this repository. Commit only their public halves here (keys/secureboot/db.crt,
        # keys/pcr/pcr.pub, keys/release/index.pgp): mkImage reads nothing else. Its `sign` signs
        # the image outside Nix with the private keys (`golconda release build`, Golconda's
        # docs/reference/release.md).
        # image =
        #   (golconda.lib.mkImage {
        #     config = ./server.toml;
        #     publicKeys = ./keys;
        #     inherit system;
        #   }).unsigned;
      };
    };
}
