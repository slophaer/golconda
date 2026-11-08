# age, the file encryption tool golconda vars stores admin vars with (cli/src/vars.rs):
# `age` and `age-keygen`. The reference implementation, as a program rather than a crate: it
# finds its plugins on PATH (age-plugin-yubikey, age-plugin-tpm), so an operator's key can stay
# in hardware. Not part of an image: it goes on PATH beside golconda (docs/reference/cli.md).
{
  package,
  sources,
  fetch,
}:
package {
  name = "age";
  uses = [ "go" ];
  go = {
    packages = [
      "./cmd/age"
      "./cmd/age-keygen"
    ];
    ldflags = [ "-X main.Version=v${sources.version}" ];
    # the module hashes repkgs keeps in its own locks/go.toml, here for this package alone
    # (module@version -> the proxy's .mod and .zip sha256; go checks go.sum's on top)
    deps = fetch.goModules {
      source = sources.fetch "default";
      locks = ./locks/go.toml;
    };
  };
  bin = [
    "age"
    "age-keygen"
  ];
}
