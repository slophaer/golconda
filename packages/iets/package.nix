# numtide's Rust Nix evaluator and remote-build client. Pinned to Golconda's commit, not the tag
{ package }:
package {
  name = "iets";
  uses = [ "cargo" ];
  tests.run = false; # the suite wants a nix daemon
}
