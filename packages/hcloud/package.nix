# hcloud: Hetzner Cloud's command line (docs/reference/hetzner-cloud.md: create the server, enable
# its rescue system, reboot it), `scripts/tool hcloud`. A deployment tool, not part of an image.
{
  package,
  sources,
  fetch,
}:
package {
  name = "hcloud";
  uses = [ "go" ];
  go = {
    packages = [ "./cmd/hcloud" ];
    # a release: no "-dev" after the version (internal/version)
    ldflags = [ "-X github.com/hetznercloud/cli/internal/version.versionPrerelease=" ];
    # module hashes in the format of repkgs' locks/go.toml, for this package alone
    deps = fetch.goModules {
      source = sources.fetch "default";
      locks = ./locks/go.toml;
    };
  };
  bin = [ "hcloud" ];
  # the version is a subcommand, not a flag
  tests.version = "version";
}
