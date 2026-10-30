# /services/<name>: one adios module per service, each returning a fragment.
{ lib, ... }:
{
  name = "services";
  modules = lib.importModules ./.;
}
