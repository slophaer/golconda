#! Container for Golconda's API to downstream modules: its one child is `/golconda/api`.
#! A group, not a component: no options, no table, no fragment of its own (`lib/components.nix`).
{ lib, ... }:
{
  name = "golconda";
  modules = lib.importModules ./.;
}
