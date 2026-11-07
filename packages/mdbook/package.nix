# mdbook: builds the book from docs/ (checks.docs, scripts/docs). A development tool, not part of
# an image.
{ package }:
package {
  name = "mdbook";
  uses = [ "cargo" ];
  # the mdbook binary of the workspace's root package (not the example preprocessor)
  cargo.flags = [
    "--package"
    "mdbook"
    "--bin"
    "mdbook"
  ];
  bin = [ "mdbook" ];
}
