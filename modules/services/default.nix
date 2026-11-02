#! Container for service modules.
#!
#! Each child module under `/services/<name>` defines one service and returns
#! a fragment for the composer. A group, not a component: it has no fragment
#! of its own. A child is an optional component, in a system when the
#! configuration has its table (`lib/components.nix`).
{ lib, ... }:
{
  name = "services";
  modules = lib.importModules ./.;
}
