#! Container for service modules.
#!
#! Each child module under `/services/<name>` defines one service and returns
#! a fragment for the composer.
{ lib, ... }:
{
  name = "services";
  modules = lib.importModules ./.;
}
