# statix: lints for Nix (treefmt's nix-statix, with statix.toml). A development tool, not part of
# an image.
{ package }:
package {
  name = "statix";
  uses = [ "cargo" ];
  # the binary is the `statix` crate of the workspace (bin/)
  cargo.flags = [
    "--package"
    "statix"
  ];
  bin = [ "statix" ];
  # its command line has no version option (`#[clap(author, about)]`)
  tests.version = false;
}
