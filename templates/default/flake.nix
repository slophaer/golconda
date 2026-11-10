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
        # The signed image: make the keys with Golconda's scripts/make-keys, keep them outside
        # this repository, and name them as a string. A string is not read at evaluation and does
        # not copy the keys into the store; the daemon needs the directory in
        # extra-sandbox-paths (Golconda's docs/reference/outputs.md, lib.mkImage).
        # image =
        #   (golconda.lib.mkImage {
        #     config = ./server.toml;
        #     keys = "/srv/golconda-keys";
        #     inherit system;
        #   }).disk;
      };
    };
}
