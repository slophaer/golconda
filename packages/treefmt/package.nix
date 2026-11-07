# treefmt: runs every formatter over the tree from one config (nix/dev), in check mode in
# checks.treefmt. A development tool, not part of an image.
{
  package,
  sources,
  fetch,
}:
package {
  name = "treefmt";
  uses = [ "go" ];
  go = {
    packages = [ "." ];
    ldflags = [
      "-X github.com/numtide/treefmt/v2/build.Name=treefmt"
      "-X github.com/numtide/treefmt/v2/build.Version=v${sources.version}"
    ];
    # module hashes in the format of repkgs' locks/go.toml, for this package alone
    deps = fetch.goModules {
      source = sources.fetch "default";
      locks = ./locks/go.toml;
    };
  };
  bin = [ "treefmt" ];
}
