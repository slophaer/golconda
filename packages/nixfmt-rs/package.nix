# nixfmt-rs: nixfmt reimplemented in Rust, with the same binary name, flags and output (verified
# against nixfmt across nixpkgs upstream). treefmt's Nix formatter (nix/dev), in place of the
# Haskell nixfmt of nixpkgs (the dev pin then). A development tool, not part of an image.
{ package, buildPkgs }:
package {
  name = "nixfmt-rs";
  uses = [ "cargo" ];
  # the merge-tool tests run `git merge-file`
  tests.dependencies = [ buildPkgs.git ];
  bin = [ "nixfmt" ];
}
