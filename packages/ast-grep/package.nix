# ast-grep: structural search and lint rules over syntax trees, the rules in lints/ (treefmt's
# ast-grep, checks.lint-rules). Rust and Nix grammars are built in; nu comes from
# packages/tree-sitter-nu. A development tool, not part of an image.
{ package }:
package {
  name = "ast-grep";
  uses = [ "cargo" ];
  # the CLI crate of the workspace, and only its ast-grep binary (not the `sg` alias)
  cargo.flags = [
    "--package"
    "ast-grep"
    "--bin"
    "ast-grep"
  ];
  bin = [ "ast-grep" ];
}
