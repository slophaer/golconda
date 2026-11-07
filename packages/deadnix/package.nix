# deadnix: finds unused bindings in Nix (treefmt's nix-deadnix, --fail --edit). A development tool,
# not part of an image.
{ package }:
package {
  name = "deadnix";
  uses = [ "cargo" ];
  bin = [ "deadnix" ];
}
