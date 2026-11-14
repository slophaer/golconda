#! A module that declares no children, though a line of its text reads like it (lib/tree.nix test).
_: {
  name = "plain";
  note = ''
    modules = none: this module has no children
  '';
}
