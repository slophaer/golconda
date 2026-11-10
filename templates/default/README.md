# A Golconda system

`server.toml` is the configuration; `flake.nix` builds it with Golconda as its one input.

- Build needs Golconda's Nix fork, with CA and dynamic derivations, on the build host. Stock Nix
  does not build it. See Golconda's `docs/reference/build-host.md`.
- `nix build` builds the `/usr` tree. For a signed image, uncomment `image` in `flake.nix`.
- `nix flake update golconda` moves Golconda to its newest commit.
- Without flakes: Golconda's `docs/reference/pinning.md` shows the same with uptrack.
