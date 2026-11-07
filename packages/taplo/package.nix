# taplo: the TOML formatter (treefmt's toml, `taplo format`). A development tool, not part of an
# image. Only the formatter: no linting against schemas fetched over the network, no language
# server, so no HTTP client and no second TLS library.
{ package }:
package {
  name = "taplo";
  uses = [ "cargo" ];
  cargo = {
    # the binary is the taplo-cli crate of the workspace
    flags = [
      "--package"
      "taplo-cli"
    ];
    noDefaultFeatures = true;
  };
  bin = [ "taplo" ];
}
