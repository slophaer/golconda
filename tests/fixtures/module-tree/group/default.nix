#! A group whose children come through `inherit`: no line starts with `modules =` (lib/tree.nix
#! test).
{ lib, ... }:
let
  children.modules = lib.importModules ./.;
in
{
  name = "group";
  inherit (children) modules;
}
